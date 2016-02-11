module fem_mod
    use  model_mod
    use  HRMC_Global
    use  scattering_factors 

    implicit none
    private
    public :: fem_initialize, fem ! for femsim
    public:: fem_update, fem_accept_move, fem_reject_move ! for hrmc
    public :: print_sampled_map
    type pos_list
        integer :: nat
        real, allocatable, dimension(:,:) :: pos ! 3 x nat array containing positions of atoms
    end type pos_list
    integer, save :: nk  ! number of k points
    integer, save, public :: nrot  ! number of rotations
    type pix_array  ! pixel array class
        real, dimension(:,:), allocatable :: pix ! npix x 2 list of pixel positions
        integer :: npix, npix_1D ! number of pixels and number of pixels in 1 dimension
        real :: phys_diam
        ! dr is the distance between pixels. Note, therefore, that there is half this
        ! distance between the pixels and the world edge. This is NOT the distance
        ! between the pixel centers. This is the distance between the edges of two
        ! different pixels. dr + phys_diam is the distance between the pixel centers!
        real :: dr
    end type pix_array
    real, save, dimension(:,:), allocatable :: rot ! nrot x 3 list of (phi, psi, theta) rotation angles
    double precision, save, dimension(:,:,:), allocatable :: int_i, int_sq ! nk x npix x nrot.  int_sq == int_i**2
    double precision, save, dimension(:,:,:), allocatable :: old_int, old_int_sq
    double precision, save, dimension(:), allocatable :: int_sum, int_sq_sum  ! nk long sums of int and int_sq arrays for calculating V(k)
    real, save, allocatable, dimension(:) :: j0, A1                                               
    type(model), save, dimension(:), pointer, public :: mrot  ! array of rotated models
    type(model), save, public :: rot_atom  ! used for rotating a single atom, overwritten every time
    type(index_list), save, dimension(:), pointer :: old_index
    type(pos_list), save, dimension(:), pointer :: old_pos 
    type(pix_array), save, public :: pa  ! pixel array instance

contains

    subroutine sort(il)
        ! Insertion sort on index list of ints
        type(index_list), intent(inout) :: il
        integer :: i, j, temp
        do i=1, il%nat
            do j=1, i
                if( il%ind(i) < il%ind(j) ) then
                    temp = il%ind(i)
                    il%ind(i) = il%ind(j)
                    il%ind(j) = temp
                end if
            end do
        end do
    end subroutine sort


    subroutine fem_initialize(m, res, k, nki, ntheta, nphi, npsi, scatfact_e, istat)
        type(model), intent(in) :: m 
        real, intent(in) :: res
        real, dimension(:), intent(in) :: k 
        integer, intent(in) :: nki, ntheta, nphi, npsi 
        real, dimension(:,:), pointer :: scatfact_e
        integer, intent(out) :: istat
        real r_max, const1, const2, const3
        integer bin_max
        integer i, j 
        integer const4 
        double precision b_x, b_j0 , b_j1 

        r_max = 2 * res ! Small pixel inscribed in Airy circle
        bin_max = int(r_max/fem_bin_width)+1

        const1 = twopi*(0.61/res)/fem_bin_width  !(0.61/res = Q) 
        const2 = 1/fem_bin_width
        const3 = (const1/(0.61/res))/const2
        const4 = int(bin_max*const3*CEILING(k(SIZE(k))))+1

        allocate(j0(0:const4),a1(0:const4), stat=istat)
        if (istat /= 0) then
            write (0,*) 'Failed to allocate memory for Bessel and Airy functions.'
            return
        endif

        ! Initialize bessel function
        j0=0.0
        do i=1, const4
            b_x = i*fem_bin_width
            call bessel_func(b_x, b_j0,b_j1)
            j0(i) = sngl(b_j0)
            a1(i) = 2*sngl(b_j1)/b_x
        enddo
        a1(0)=1.0
        j0(0)=1.0

        nk = nki

        call init_rot(ntheta, nphi, npsi, nrot, istat)
        call init_pix(m, res, istat)

        allocate(int_i(nk, pa%npix, nrot), old_int(nk, pa%npix, nrot), old_int_sq(nk, pa%npix, nrot), &
            int_sq(nk, pa%npix, nrot), int_sum(nk), int_sq_sum(nk), stat=istat)
        call check_for_error(istat, 'Problem allocating memory in fem_initialize.')

        ! Allocate memory for rot_atom model.
        rot_atom%lx = m%lx
        rot_atom%ly = m%ly
        rot_atom%lz = m%lz
        rot_atom%rotated = .TRUE.
        rot_atom%unrot_natoms = 1
        rot_atom%natoms = 0
        ! Allocating space for 10 duplicates -- there will *never* be that many
        ! rot_i should never be used so I wont allocate or deal with it.
        allocate(rot_atom%xx%ind(10), rot_atom%yy%ind(10), rot_atom%zz%ind(10), &
            rot_atom%znum%ind(10), rot_atom%znum_r%ind(10), stat=istat)
        rot_atom%xx%nat = rot_atom%natoms
        rot_atom%yy%nat = rot_atom%natoms
        rot_atom%zz%nat = rot_atom%natoms
        rot_atom%znum%nat = rot_atom%natoms
        rot_atom%znum_r%nat = rot_atom%natoms
        call check_for_error(istat, 'Problem allocating memory in fem_initialize.')

        if( mod(m%lx,pa%phys_diam) >= 0.001 ) then
            write(0,*) "WARNING! Your world size should be an integer multiple of the resolution. Pixel diameter = ", pa%phys_diam, ". World size = ", m%lx
        endif

        call read_f_e
        allocate(scatfact_e(m%nelements,nk), stat=istat)
        call check_for_error(istat, 'Allocation of electron scattering factors table failed.')

        do j=1,m%nelements
            do i=1, nk
                scatfact_e(j,i)=f_e(m%atom_type(j),k(i))
            enddo
        enddo
    end subroutine fem_initialize


    subroutine bessel_func(x,bj0,bj1)
        implicit none 
        doubleprecision :: A,B,A1,B1,BJ0,BJ1,BY0,BY1,DY0,DY1,X,X2,RP2,DJ0,DJ1,R,DABS
        doubleprecision :: EC,CS0,W0,R0,CS1,W1,R1,T1,T2,P0,P1,Q0,Q1,CU,DCOS,DSIN
        integer :: k,k0 
        dimension :: A(12),B(12),A1(12),B1(12)

        RP2=0.63661977236758D0
        X2=X*X
        IF (X.EQ.0.0D0) THEN 
            BJ0=1.0D0
            BJ1=0.0D0
            DJ0=0.0D0
            DJ1=0.5D0
            BY0=-1.0D+300
            BY1=-1.0D+300
            DY0=1.0D+300
            DY1=1.0D+300
            RETURN
        ENDIF
        IF (X.LE.12.0D0) THEN 
            BJ0=1.0D0
            R=1.0D0
            DO 5 K=1,30
                R=-0.25D0*R*X2/(K*K)
                BJ0=BJ0+R
                IF (DABS(R).LT.DABS(BJ0)*1.0D-15) GO TO 10
5           CONTINUE
10          BJ1=1.0D0
            R=1.0D0
            DO 15 K=1,30
                R=-0.25D0*R*X2/(K*(K+1.0D0))
                BJ1=BJ1+R
                IF (DABS(R).LT.DABS(BJ1)*1.0D-15) GO TO 20
15          CONTINUE
20          BJ1=0.5D0*X*BJ1
            EC=DLOG(X/2.0D0)+0.5772156649015329D0
            CS0=0.0D0
            W0=0.0D0
            R0=1.0D0
            DO 25 K=1,30
                W0=W0+1.0D0/K
                R0=-0.25D0*R0/(K*K)*X2
                R=R0*W0
                CS0=CS0+R
                IF (DABS(R).LT.DABS(CS0)*1.0D-15) GO TO 30
25          CONTINUE
30          BY0=RP2*(EC*BJ0-CS0)
            CS1=1.0D0
            W1=0.0D0
            R1=1.0D0
            DO 35 K=1,30
                W1=W1+1.0D0/K
                R1=-0.25D0*R1/(K*(K+1))*X2
                R=R1*(2.0D0*W1+1.0D0/(K+1.0D0))
                CS1=CS1+R
                IF (DABS(R).LT.DABS(CS1)*1.0D-15) GO TO 40
35          CONTINUE
40          BY1=RP2*(EC*BJ1-1.0D0/X-0.25D0*X*CS1)
        ELSE

            DATA A/-.7031250000000000D-01,.1121520996093750D+00, &
            -.5725014209747314D+00,.6074042001273483D+01, &
            -.1100171402692467D+03,.3038090510922384D+04, &
            -.1188384262567832D+06,.6252951493434797D+07, &
            -.4259392165047669D+09,.3646840080706556D+11, &
            -.3833534661393944D+13,.4854014686852901D+15/
            DATA B/ .7324218750000000D-01,-.2271080017089844D+00, &
            .1727727502584457D+01,-.2438052969955606D+02, &
            .5513358961220206D+03,-.1825775547429318D+05, &
            .8328593040162893D+06,-.5006958953198893D+08, &
            .3836255180230433D+10,-.3649010818849833D+12, &
            .4218971570284096D+14,-.5827244631566907D+16/
            DATA A1/.1171875000000000D+00,-.1441955566406250D+00, &
            .6765925884246826D+00,-.6883914268109947D+01, &
            .1215978918765359D+03,-.3302272294480852D+04, &
            .1276412726461746D+06,-.6656367718817688D+07, &
            .4502786003050393D+09,-.3833857520742790D+11, &
            .4011838599133198D+13,-.5060568503314727D+15/
            DATA B1/-.1025390625000000D+00,.2775764465332031D+00, &
            -.1993531733751297D+01,.2724882731126854D+02, &
            -.6038440767050702D+03,.1971837591223663D+05, &
            -.8902978767070678D+06,.5310411010968522D+08, &
            -.4043620325107754D+10,.3827011346598605D+12, &
            -.4406481417852278D+14,.6065091351222699D+16/

            K0=12
            IF (X.GE.35.0) K0=10
            IF (X.GE.50.0) K0=8
            T1=X-0.25D0*PI
            P0=1.0D0
            Q0=-0.125D0/X
            DO 45 K=1,K0
                P0=P0+A(K)*X**(-2*K)
45              Q0=Q0+B(K)*X**(-2*K-1)
            CU=DSQRT(RP2/X)
            BJ0=CU*(P0*DCOS(T1)-Q0*DSIN(T1))
            BY0=CU*(P0*DSIN(T1)+Q0*DCOS(T1))
            T2=X-0.75D0*PI
            P1=1.0D0
            Q1=0.375D0/X
            DO 50 K=1,K0
                P1=P1+A1(K)*X**(-2*K)
50              Q1=Q1+B1(K)*X**(-2*K-1)
            CU=DSQRT(RP2/X)
            BJ1=CU*(P1*DCOS(T2)-Q1*DSIN(T2))
            BY1=CU*(P1*DSIN(T2)+Q1*DCOS(T2))
        ENDIF
        DJ0=-BJ1
        DJ1=BJ0-BJ1/X
        DY0=-BY1
        DY1=BY0-BY1/X
        RETURN
    end subroutine bessel_func


    subroutine init_rot(ntheta, nphi, npsi, num_rot, istat)
    ! Calculates the rotation angles and initializes them into the global
    ! rotation array rot.
        integer, intent(in) :: ntheta, nphi, npsi
        integer, intent(out) :: istat
        integer :: i,j, k, jj
        real,dimension(3) :: step_size
        integer :: ntheta_w(nphi*npsi)
        integer, intent(out) :: num_rot
        real, dimension(:,:), allocatable :: rot_temp
        real :: psi_temp
        integer :: pp

        allocate(rot_temp(ntheta*nphi*npsi,3), stat=istat)
        if (istat /= 0) then
           write (0,*) 'Cannot allocate temporary rotations array.'
           return
        endif

        ! phi runs from 0 to 2 PI
        ! psi runs from 0 to 2 PI
        ! theta runs from 0 to PI
        ! step_size(1) for phi step    
        ! step_size(2) for psi step
        ! step_size(3) for theta step
        step_size(1) = TWOPI / nphi
        step_size(2) = TWOPI / npsi
        step_size(3) = PI / ntheta

        jj = 1
        do i=1, nphi
            do j=1, npsi/2
                psi_temp = (j-1)*step_size(2)
                ntheta_w(j) = int(sin(psi_temp)*ntheta)
                if(ntheta_w(j).ge.0)then
                    if(ntheta_w(j).gt.0) then
                        pp = 2*(ntheta_w(j)-1)
                    else if(ntheta_w(j).eq.0) then
                        pp = 1
                    endif
                    do k=1, pp
                        if(k*(pi/(ntheta_w(j)-1)).lt.pi)then
                            rot_temp(jj,1) = (i-1)*step_size(1)
                            rot_temp(jj,2) = (j-1)*step_size(2)
                            if(ntheta_w(j) .eq. 0) then
                                rot_temp(jj,3) = 0.0
                            else
                                rot_temp(jj,3) = k*(pi/(ntheta_w(j)-1))
                            endif
                            jj = jj + 1
                        endif
                    enddo
                endif
            enddo
        enddo

        num_rot = jj - 1
        if(myid .eq. 0) write(*,*) "Number of rotations:", num_rot

        allocate(rot(num_rot, 3), stat=istat)
        if (istat /= 0) then
           write (0,*) 'Cannot allocate rotations array.'
           return
        endif

        do i=1, num_rot
            rot(i,1) = rot_temp(i,1)
            rot(i,2) = rot_temp(i,2)
            rot(i,3) = rot_temp(i,3)
        enddo
        
        if(rot(1,1) .ne. 0.0 .or. rot(1,2) .ne. 0.0 .or. rot(1,3) .ne. 0.0) then
            write(0,*) "WARNING: ERROR: The first rotation MUST be 0,0,0!"
            write(0,*) "They currently are", rot(1,1), rot(1,2), rot(1,3)
        endif

        deallocate(rot_temp)
    end subroutine init_rot


    subroutine init_pix(m, res, istat)
        type(model), intent(in) :: m
        real, intent(in) :: res
        integer, intent(out) :: istat
        integer :: i, j, k

        pa%phys_diam = res * sqrt(2.0)

        if( pa%phys_diam - m%lx > 0) then ! Rounding error.
            pa%phys_diam = m%lx
            ! Something weird was going on here if I didn't do this. It was a
            ! result of pa%phys_diam being larger than m%lx by a tiny amount
            ! due to rounding errors from the inputs. This seems to work.
            write(0,*)
            write(0,*) "WARNING: There was a rounding error in init_pix, it was manually corrected but you should check to make sure you don't have things set up so that your pixel diameter is larger than your model."
            write(0,*)
        endif
        pa%npix_1D = floor( m%lx / pa%phys_diam )
        pa%npix = pa%npix_1D**2

        pa%dr = m%lx/pa%npix_1D - pa%phys_diam

        allocate(pa%pix(pa%npix, 2), stat=istat)
        if (istat /= 0) then
            write (*,*) 'Cannot allocate pixel position array.'
            return
        endif

        k=1
        do i=1, pa%npix_1D
            do j=1, pa%npix_1D
                pa%pix(k,1) = -m%lx/2.0 + (pa%phys_diam+pa%dr)/2.0 + (pa%phys_diam+pa%dr)*(i-1)
                pa%pix(k,2) = -m%ly/2.0 + (pa%phys_diam+pa%dr)/2.0 + (pa%phys_diam+pa%dr)*(j-1)
                k = k + 1
            enddo
        enddo

        if(myid.eq.0)then
            write(*,*)"Pixel configuration: ", pa%npix_1D, "by", pa%npix_1D
            write(*,*) "They are centered at:"
            k=1
            do i=1, pa%npix_1D
                do j=1, pa%npix_1D
                    write(*,*)"(", pa%pix(k,1), ",", pa%pix(k,2), ")"
                    k=k+1
                enddo
            enddo
            write(*,*) "with a distance between pixels of", pa%dr
            write(*,*) "and a diameter of", pa%phys_diam
        endif
    end subroutine init_pix


    subroutine fem(m, res, k, vk, scatfact_e, comm, istat, rot_begin, rot_end)
        use mpi
        implicit none
        type(model), intent(in) :: m
        real, intent(in) :: res
        real, dimension(:), intent(in) :: k
        double precision, dimension(:), INTENT(OUT) :: vk
        real, dimension(:,:), pointer :: scatfact_e
        integer, intent(out) :: istat
        integer, optional, intent(in) :: rot_begin, rot_end
        double precision, dimension(:), allocatable :: psum_int, psum_int_sq, sum_int, sum_int_sq
        integer :: comm
        integer :: i, j
        integer begin_rot, end_rot

        if(present(rot_begin)) then
            begin_rot = rot_begin
        else
            begin_rot  = 1
        endif

        if(present(rot_end)) then
            end_rot = rot_end
        else
            end_rot = nrot ! This is set in fem_initialize->init_rot
        endif

        allocate (psum_int(size(k)), psum_int_sq(size(k)), sum_int(size(k)), sum_int_sq(size(k)), stat=istat)
        sum_int = 0.0
        sum_int_sq = 0.0
        psum_int = 0.0
        psum_int_sq = 0.0

        ! initialize the rotated models
        allocate(mrot(nrot), stat=istat)
        call check_for_error(istat, 'Cannot allocate rotated model array.')

        ! Calculate all the rotated models and save them in mrot.
        do i=myid+1, nrot, numprocs
            call rotate_model(rot(i, 1), rot(i, 2), rot(i, 3), m, mrot(i), istat)
            call check_for_error(istat, 'Failed to rotate model')
            mrot(i)%id = i
        enddo

        allocate(old_index(nrot), old_pos(nrot), stat=istat)
        call check_for_error(istat, 'Cannot allocate memory for old indices and positions in fem_initialize.')
        ! Initialize old_index and old_pos arrays. The if statements should
        ! be unnecessary, but they don't hurt. Better safe than sorry.
        do i=myid+1, nrot, numprocs
            old_index(i)%nat = 0
            if( allocated(old_index(i)%ind) ) deallocate(old_index(i)%ind)
            old_pos(i)%nat = 0
            if( allocated(old_pos(i)%pos) ) deallocate(old_pos(i)%pos)
        enddo

        ! Calculate intensities for every single pixel in every single model. This is very expensive.
        if(myid .eq. 0) then
            write(*,*); write(*,*) "Calculating intensities over the models: nrot = ", nrot; write(*,*)
        endif
        do i=myid+1, nrot, numprocs
            do j=1, pa%npix
#ifdef DEBUG
                write(*,*) "Calling intensity on pixel (", pa%pix(j,1), ",",pa%pix(j,2), ") in rotated model ", i, "with core", myid
#endif
                call intensity(mrot(i), res, pa%pix(j, 1), pa%pix(j, 2), k, int_i(1:nk, j, i), scatfact_e, istat)
                int_sq(1:nk, j, i) = int_i(1:nk, j, i)**2
                psum_int(1:nk) = psum_int(1:nk) + int_i(1:nk, j, i)
                psum_int_sq(1:nk) = psum_int_sq(1:nk) + int_sq(1:nk, j, i)
            enddo
#ifdef DEBUG
            write(*,*) "Finished intensity calls on model", i
#endif
        enddo

        call mpi_barrier(comm, mpierr)
        call mpi_reduce (psum_int, sum_int, size(k), mpi_double, mpi_sum, 0, comm, mpierr)
        call mpi_reduce (psum_int_sq, sum_int_sq, size(k), mpi_double, mpi_sum, 0, comm, mpierr)

        if(myid.eq.0)then
            do i=1, nk
                Vk(i) = (sum_int_sq(i)/(pa%npix*nrot))/((sum_int(i)/(pa%npix*nrot))**2)-1.0
            end do
        endif

        deallocate(psum_int, psum_int_sq, sum_int, sum_int_sq)
    end subroutine fem

    subroutine intensity(m_int, res, px, py, k, int_i, scatfact_e, istat)
    ! Calculates int_i for output.
        use  omp_lib
        include 'mpif.h'
        type(model), intent(inout) :: m_int
        real, intent(in) :: res, px, py
        real, dimension(nk), intent(in) :: k
        double precision, dimension(nk), intent(inout) :: int_i
        real, dimension(:,:), pointer :: scatfact_e
        integer, intent(out) :: istat
        real, dimension(:,:,:), allocatable :: gr_i
        real, dimension(:), allocatable ::x1, y1, rr_a
        real, dimension(:,:), allocatable :: sum1
        real :: x2, y2, rr, t1, t2, const1, const2, const3, pp, r_max
        integer, pointer, dimension(:) :: pix_atoms, znum_r
        integer :: i,j,ii,jj,kk
        integer :: bin_max, size_pix_atoms
        real, allocatable, dimension(:) :: rr_x, rr_y
        real :: sqrt1_2_res
        real :: k_1

        sqrt1_2_res = sqrt(0.5) * res
        r_max = 2*res ! small pixel inscribed in airy circle
        call hutch_list_pixel_sq(m_int, px, py, pa%phys_diam, pix_atoms, istat)
        allocate( rr_x(size(pix_atoms)),rr_y(size(pix_atoms)), stat=istat)

        size_pix_atoms = size(pix_atoms)
        bin_max = int(r_max/fem_bin_width)+1

        allocate(gr_i(m_int%nelements,m_int%nelements, 0:bin_max), stat=istat)
        allocate(x1(size_pix_atoms),y1(size_pix_atoms),rr_a(size_pix_atoms), stat=istat)
        allocate(sum1(m_int%nelements,size_pix_atoms), stat=istat)
        allocate(znum_r(size_pix_atoms), stat=istat)

        do i=1, size_pix_atoms
            znum_r(i) = m_int%znum_r%ind(pix_atoms(i))
        enddo

        gr_i = 0.0; int_i = 0.0; x1 = 0.0; y1 = 0.0; rr_a = 0.0

        x2 = 0.0; y2 = 0.0
        const1 = twopi*(0.61/res)/fem_bin_width  ! (0.61/res = Q)
        const2 = 1/fem_bin_width
        const3 = TWOPI

        ! Calculate sum1 for gr_i calculation in next loop.
        do i=1,size_pix_atoms
            x2=m_int%xx%ind(pix_atoms(i))-px
            y2=m_int%yy%ind(pix_atoms(i))-py
            x2=x2-m_int%lx*anint(x2/m_int%lx)
            y2=y2-m_int%ly*anint(y2/m_int%ly)
            rr_x(i) = ABS(x2)
            rr_y(i) = ABS(y2)
            rr_a(i)=sqrt(x2*x2 + y2*y2)
            if((rr_x(i) .le. sqrt1_2_res) .AND. (rr_y(i) .le.  sqrt1_2_res))then !small pixel inscribed in Airy circle
                k_1=0.82333
                x1(i)=x2
                y1(i)=y2
                j=int(const1*rr_a(i))
                sum1(znum_r(i),i)=A1(j)
            endif
        enddo

        ! Calculate gr_i for int_i in next loop.
        do i=1,size_pix_atoms
            if((rr_x(i).le.sqrt1_2_res) .and. (rr_y(i) .le.  sqrt1_2_res))then
                do j=i,size_pix_atoms
                    if((rr_x(j).le.sqrt1_2_res) .and. (rr_y(j) .le. sqrt1_2_res))then
                        x2=x1(i)-x1(j)
                        y2=y1(i)-y1(j)
                        rr=sqrt(x2*x2 + y2*y2)
                        kk=int(const2*rr)
                        if(i == j)then
                            t1=sum1(znum_r(i),i)
                            gr_i(znum_r(i),znum_r(j),kk)=gr_i(znum_r(i),znum_r(j),kk)+t1*t1
                        else
                            t1=sum1(znum_r(i),i)
                            t2=sum1(znum_r(j),j)
                            gr_i(znum_r(i),znum_r(j),kk)=gr_i(znum_r(i),znum_r(j),kk)+2.0*t1*t2
                        endif
                    endif
                enddo
            endif
        enddo

        do i=1,nk
            do j=0,bin_max
                do ii=1,m_int%nelements
                    do jj=1,m_int%nelements
                        pp=const3*j*k(i)
                        int_i(i)=int_i(i)+scatfact_e(ii,i)*scatfact_e(jj,i)*J0(INT(pp))*gr_i(ii,jj,j)
                    enddo
                enddo
            end do
        end do

        if(allocated(gr_i))      deallocate(gr_i)
        if(allocated(x1))        deallocate(x1,y1, rr_a, znum_r)
        if(size(pix_atoms).gt.0) deallocate(pix_atoms)
        if(allocated(sum1))      deallocate(sum1)
        if(allocated(rr_x))      deallocate(rr_x, rr_y)
    end subroutine intensity


    subroutine move_atom_in_rotated_model(atom,mroti,i)
        ! WARNING! rot_atom is implicitly used in this function.
        ! It is basically a mandatory parameter, and needs to be 
        ! updated correctly BEFORE calling this function.
        implicit none
        integer, intent(in) :: atom
        type(model), intent(inout) :: mroti
        integer, intent(in) :: i
        integer :: j

        ! ------- Update atoms in the rotated model. ------- !
        if( mroti%rot_i(atom)%nat .eq. rot_atom%natoms ) then
        ! The atom simply moved. It is still in the rotated model the
        ! same number of times as before.
            do j=1,rot_atom%natoms
#ifdef DEBUG
                ! Function ref: move_atom(m, atom, new_xx, new_yy, new_zz)
                write(*,*) "Atom", mroti%rot_i(atom)%ind(j), " !==!", atom, "simply moved positions in model", mroti%id
                write(*,*) "Atom", mroti%rot_i(atom)%ind(j), " !==!", atom, "simply moved positions. It's moving from", mroti%xx%ind(mroti%rot_i(atom)%ind(j)),  mroti%yy%ind(mroti%rot_i(atom)%ind(j)), mroti%zz%ind(mroti%rot_i(atom)%ind(j)), "to", rot_atom%xx%ind(j), rot_atom%yy%ind(j), rot_atom%zz%ind(j)
                write(*,*) "Its current (old) rot_i=", mroti%rot_i(atom)%ind
#endif
                call move_atom(mroti, mroti%rot_i(atom)%ind(j), &
                rot_atom%xx%ind(j), rot_atom%yy%ind(j), rot_atom%zz%ind(j) )
            enddo

        else if( rot_atom%natoms .ge. mroti%rot_i(atom)%nat ) then
            ! The number of times the atom appears went up (duplication).
            ! Set old_index(i)%nat to -1 so that fem_reject_move knows that
            ! the number of atoms was changed.
            old_index(i)%nat = -1
            
#ifdef DEBUG
            write(*,*) "Atom", atom, "increased the number of times it occurs in model", mroti%id
            if(allocated(mroti%rot_i(atom)%ind)) then
                write(*,*) "Its current (old) rot_i=", mroti%rot_i(atom)%ind
            else
                write(*,*) "Its current (old) rot_i=0"
            endif
#endif

            ! The atom positions in the rotated model (not atom) should
            ! be updated *up to the number of times it appeared in the
            ! model before*. This saves deleting rot_i(atom) and
            ! re-implementing it, as well as all the atoms it points to.
            do j=1,mroti%rot_i(atom)%nat
#ifdef DEBUG
            write(*,*) "Moving", mroti%rot_i(atom)%ind(j), "from", mroti%xx%ind(mroti%rot_i(atom)%ind(j)),  mroti%yy%ind(mroti%rot_i(atom)%ind(j)), mroti%zz%ind(mroti%rot_i(atom)%ind(j)), "to", rot_atom%xx%ind(j), rot_atom%yy%ind(j), rot_atom%zz%ind(j)
#endif
                call move_atom(mroti, mroti%rot_i(atom)%ind(j), &
                rot_atom%xx%ind(j), rot_atom%yy%ind(j), rot_atom%zz%ind(j) )
            enddo

            ! Now add the rest of the atom positions in rot_atom that we
            ! haven't gotten to yet.
            do j=mroti%rot_i(atom)%nat+1, rot_atom%natoms
                call add_atom(mroti, atom, rot_atom%xx%ind(j), rot_atom%yy%ind(j), rot_atom%zz%ind(j), rot_atom%znum%ind(j), rot_atom%znum_r%ind(j) )
#ifdef DEBUG
                write(*,*) "Added to", mroti%xx%ind(mroti%rot_i(atom)%ind(j)),  mroti%yy%ind(mroti%rot_i(atom)%ind(j)), mroti%zz%ind(mroti%rot_i(atom)%ind(j))
#endif
            enddo

        else if( mroti%rot_i(atom)%nat .gt. rot_atom%natoms ) then
            ! The number of times the atom appears in the rotated model went down.
            ! Set old_index(i)%nat to -1 so that fem_reject_move knows that
            ! the number of atoms was changed.
            old_index(i)%nat = -1
        
#ifdef DEBUG
            write(*,*) "Atom", atom, "decreased the number of times it occurs in model", mroti%id
            write(*,*) "Its current (old) rot_i=", mroti%rot_i(atom)%ind
#endif

            ! First I want to sort the indices in mroti%rot_i(atom)
            ! so that when we delete an atom from this array we will
            ! always be deleting the atom with the highest index. That
            ! way our array deletion is faster in the remove_atom
            ! function.
            call sort(mroti%rot_i(atom))

            ! The atom positions in the rotated model (not atom) should
            ! be updated up to the number of atoms in rot_atom. This
            ! saves deleting rot_i(atom) and re-implementing it, as well
            ! as all the atoms it points to.
            do j=1,rot_atom%natoms
#ifdef DEBUG
            write(*,*) "Moving", mroti%rot_i(atom)%ind(j), "from", mroti%xx%ind(mroti%rot_i(atom)%ind(j)),  mroti%yy%ind(mroti%rot_i(atom)%ind(j)), mroti%zz%ind(mroti%rot_i(atom)%ind(j)), "to", rot_atom%xx%ind(j), rot_atom%yy%ind(j), rot_atom%zz%ind(j)
#endif
                call move_atom(mroti, mroti%rot_i(atom)%ind(j), &
                rot_atom%xx%ind(j), rot_atom%yy%ind(j), rot_atom%zz%ind(j) )
            enddo

            ! Now we delete the extras that were in the model before.
            ! The thing you need to be careful of is that remove_atom
            ! deletes from mroti%rot_i(atom)%ind. This means that the
            ! next call to remove_atom needs the same index, not the
            ! next one. So instead of j, we use rot_atom%natoms+1,
            ! which is the starting point of j.
            ! But we still need to call remove_atom j times.
            do j=rot_atom%natoms+1, mroti%rot_i(atom)%nat
                call remove_atom(mroti, atom, mroti%rot_i(atom)%ind(rot_atom%natoms+1) )
            enddo
        endif
    end subroutine move_atom_in_rotated_model


    subroutine fem_update(m_in, atom, res, k, vk, scatfact_e, comm, istat)
        use mpi
        type(model), intent(in) :: m_in
        integer, intent(in) :: atom
        real, intent(in) :: res
        real, dimension(:), intent(in) :: k
        double precision, dimension(:), intent(out) :: vk
        real, dimension(:,:), pointer :: scatfact_e
        integer, intent(out) :: istat
        double precision, dimension(:), allocatable :: psum_int, psum_int_sq, sum_int, sum_int_sq
        integer :: comm
        type(model) :: moved_atom
        integer :: i, j, m, n, ntpix
        logical, dimension(:,:), allocatable :: update_pix
        type(index_list) :: pix_il

        istat = 0
        allocate(update_pix(nrot,pa%npix),stat=istat)
        call check_for_error(istat, 'Cannot allocate memory for pixel update array in fem.')
        update_pix = .FALSE.
        call check_for_error(istat, 'Cannot allocate memory for pixel update array in fem.')

        ! Create a new model (moved_atom) with only one atom in it and put the
        ! position etc of the moved atom into it.
        allocate(moved_atom%xx%ind(1), moved_atom%yy%ind(1), moved_atom%zz%ind(1), &
            moved_atom%znum%ind(1), moved_atom%atom_type(1), moved_atom%znum_r%ind(1), &
            stat=istat)
        moved_atom%natoms = 1
        ! m_in%xx%ind, etc have already been updated by random_move so these are the
        ! new, moved atom positions.
        moved_atom%xx%ind(1) = m_in%xx%ind(atom)
        moved_atom%yy%ind(1) = m_in%yy%ind(atom)
        moved_atom%zz%ind(1) = m_in%zz%ind(atom)
        moved_atom%znum%ind(1) = m_in%znum%ind(atom)
        moved_atom%znum_r%ind(1) = m_in%znum_r%ind(atom)
        moved_atom%lx = m_in%lx
        moved_atom%ly = m_in%ly
        moved_atom%lz = m_in%lz
        moved_atom%nelements = 1
        moved_atom%atom_type(1) = m_in%znum%ind(atom)
        moved_atom%rotated = .FALSE.

        ! Initialize the intensity arrays.
        allocate(psum_int(size(k)), psum_int_sq(size(k)), sum_int(size(k)), &
        sum_int_sq(size(k)), stat=istat)

        old_int=0.0; old_int_sq=0.0
        sum_int = 0.0; sum_int_sq = 0.0
        psum_int = 0.0; psum_int_sq = 0.0

        ! ------- Rotate models and call intensity on necessary pixels. ------- !
#ifdef DEBUG
        write(*,*) "Rotating, etc ", nrot, " single atom models in fem_update."
        write(*,*) "We have", numprocs, "processor(s)."
#endif
        rotations: do i=myid+1, nrot, numprocs

            ! Store the current (soon to be old) intensities for fem_reject_move
            ! so we don't lose them upon recalculation.
            do m=1, pa%npix
                old_int(1:nk, m, i) = int_i(1:nk, m, i)
                old_int_sq(1:nk, m, i) = int_sq(1:nk, m, i)
            enddo

            ! Rotate that moved_atom into rot_atom. moved_atom is unchanged.
            call rotate_atom(rot(i,1), rot(i, 2), rot(i, 3), moved_atom, rot_atom, istat)
            ! Note that mrot is the array containing the rotated models with
            ! every atom in them; it is different than these. rot_atom now
            ! contains a model that needs to be incorporated into mrot(i) in the
            ! appropriate manner.

            ! Some notes before you start reading this:
            ! If mrot(i)%rot_i(atom)%nat == 0  then the atom was not in the
            ! rotated model at all before this function.
            ! If rot_atom%natoms == 0 then the rotation of the atom moved it
            ! outside the model, or it remained outside the atom upon the rot.
            ! Basically, mrot(i)%rot_i(atom)%nat is the number of times the atom
            ! was in the rotated model before this function, and rot_atom%natoms
            ! is the number of times it is in rotated model after this function.
            ! Note, also, that if the change in the number of times atom appears
            ! in the model is greater than 1 then we are reallocating and
            ! deallocating and potentially performing array deletion
            ! unnecessarily a bit, but this should happen semi rarely and it
            ! shouldn't be THAT much slower. I should probably check. However,
            ! once if we change the reallocation to 10% instead of just a single
            ! spot then it's much less big of a deal. Something like this is
            ! done.

            ! First check to see if:
            ! (rot_atom%natoms == 0) .and. (mrot(i)%rot_i(atom)%nat == 0).
            ! If that is true, the rotated atom left the model previously and
            ! did not reenter so there is no structural change - we can skip to
            ! the end of the rotations do loop.
            if( .not. ((rot_atom%natoms == 0) .and. (mrot(i)%rot_i(atom)%nat == 0)) ) then
#ifdef DEBUG
                write(*,*) "mod=", i, "mrot", mrot(i)%rot_i(atom)%nat, "r=", rot_atom%natoms, "mrot%nat=", mrot(i)%natoms ! Debug
#endif

                ! Store the original index(es) and position(s) in old_index and old_pos
                do j=1,mrot(i)%rot_i(atom)%nat
                    call add_index(old_index(i), mrot(i)%rot_i(atom)%ind(j))
                    call add_pos(old_pos(i), mrot(i)%xx%ind(mrot(i)%rot_i(atom)%ind(j)), &
                        mrot(i)%yy%ind(mrot(i)%rot_i(atom)%ind(j)), &
                        mrot(i)%zz%ind(mrot(i)%rot_i(atom)%ind(j)), istat)
                enddo

                ! ------- Update pixels for original and new positions. ------- !

                ! Now check if the original position of the moved atom is inside
                ! each pixel. If so, that intensity must be recalculated.
                do n=1, mrot(i)%rot_i(atom)%nat
                    call pixel_positions(old_pos(i)%pos(n,1), &
                        old_pos(i)%pos(n,2), pix_il)
                    do m=1,pix_il%nat
                        update_pix(i,pix_il%ind(m)) = .TRUE.
                    enddo
                enddo
                ! Now check if the position of the rotated atom is inside
                ! each pixel. If so, that intensity must be recalculated.
                do n=1, rot_atom%natoms
                    call pixel_positions(rot_atom%xx%ind(n), &
                        rot_atom%yy%ind(n), pix_il)
                    do m=1,pix_il%nat
                        update_pix(i,pix_il%ind(m)) = .TRUE.
                    enddo
                enddo

                ! ------- Update atoms in the rotated model. ------- !
#ifdef DEBUG
                write(*,*) "Moving atom", atom, mrot(i)%rot_i(atom)%nat
                do n=1, mrot(i)%rot_i(atom)%nat
                    write(*,*) "  from", mrot(i)%xx%ind(mrot(i)%rot_i(atom)%ind(n)), mrot(i)%yy%ind(mrot(i)%rot_i(atom)%ind(n)), mrot(i)%zz%ind(mrot(i)%rot_i(atom)%ind(n))
                enddo
                do n=1, rot_atom%natoms
                    write(*,*) "  to  ", rot_atom%xx%ind(n), rot_atom%yy%ind(n), rot_atom%zz%ind(n)
                enddo
#endif
                call move_atom_in_rotated_model(atom,mrot(i),i)
#ifdef DEBUG
                write(*,*) "Moved atom", atom, mrot(i)%rot_i(atom)%nat
                do n=1, mrot(i)%rot_i(atom)%nat
                    write(*,*) "  to  ", mrot(i)%xx%ind(mrot(i)%rot_i(atom)%ind(n)), mrot(i)%yy%ind(mrot(i)%rot_i(atom)%ind(n)), mrot(i)%zz%ind(mrot(i)%rot_i(atom)%ind(n))
                enddo

                ! Error check!
                do n=1, rot_atom%natoms
                    if( rot_atom%xx%ind(n) .ne.  mrot(i)%xx%ind(mrot(i)%rot_i(atom)%ind(n)) ) write(*,*) "ERROR! x coord moved wrong!", atom, rot_atom%xx%ind(n), mrot(i)%xx%ind(mrot(i)%rot_i(atom)%ind(n))
                    if( rot_atom%yy%ind(n) .ne.  mrot(i)%yy%ind(mrot(i)%rot_i(atom)%ind(n)) ) write(*,*) "ERROR! y coord moved wrong!", atom, rot_atom%yy%ind(n), mrot(i)%yy%ind(mrot(i)%rot_i(atom)%ind(n))
                    if( rot_atom%zz%ind(n) .ne.  mrot(i)%zz%ind(mrot(i)%rot_i(atom)%ind(n)) ) write(*,*) "ERROR! z coord moved wrong!", atom, rot_atom%zz%ind(n), mrot(i)%zz%ind(mrot(i)%rot_i(atom)%ind(n))
                enddo
#endif

            endif ! Test to see if (rot_atom%natoms == 0) .and. (mrot(i)%rot_i(atom)%nat == 0)

        enddo rotations

#ifdef DEBUG
        ntpix = 0
        do i=1, nrot
            do m=1, pa%npix
                if(update_pix(i,m) == .TRUE.) then
                    ntpix = ntpix + 1
                endif
            enddo
        enddo
        write(*,*) "Calling Intensity on ", ntpix, " pixels."
        write(*,*) "Average number of pixels to call intensity on per model:", real(ntpix)/211.0
#endif

        ! In this loop, 'i' is the model that has intensity called on it.
        do i=myid+1, nrot, numprocs
            do m=1, pa%npix
                if(update_pix(i,m)) then
#ifdef DEBUG
                    write(*,*) "Calling intensity in MC on pixel (", pa%pix(m,1), ",",pa%pix(m,2), ") in rotated model ", i, "with core", myid
#endif
                    call intensity(mrot(i), res, pa%pix(m, 1), pa%pix(m, 2), k, int_i(1:nk, m, i), scatfact_e,istat)
                    int_sq(1:nk, m, i) = int_i(1:nk, m, i)**2
                endif
            enddo
        enddo
#ifdef DEBUG
        write(*,*) "I am core", myid, "and I am past the int calls."
#endif
        
        ! Set psum_int and psum_int_sq. This MUST be done inside an MPI loop
        ! with the exact same structure as the MPI loop that called intensity.
        do i=myid+1, nrot, numprocs
            do m=1, pa%npix
                psum_int(1:nk) = psum_int(1:nk) + int_i(1:nk, m, i)
                psum_int_sq(1:nk) = psum_int_sq(1:nk) + int_sq(1:nk, m, i)
            enddo
        enddo
#ifdef DEBUG
        write(*,*) "I am core", myid, "and I am past the psum_int setters."
#endif

        call mpi_barrier(comm, mpierr)
        call mpi_reduce (psum_int, sum_int, size(k), mpi_double, mpi_sum, 0, comm, mpierr)
        call mpi_reduce (psum_int_sq, sum_int_sq, size(k), mpi_double, mpi_sum, 0, comm, mpierr)
#ifdef DEBUG
        write(*,*) "I am core", myid, "and I am past mpi_reduce."
#endif

        ! Recalculate the variance
        if(myid.eq.0)then
            do i=1, nk
                Vk(i) = (sum_int_sq(i)/(pa%npix*nrot))/((sum_int(i)/(pa%npix*nrot))**2)-1.0
            end do
        endif

        deallocate(moved_atom%xx%ind, moved_atom%yy%ind, moved_atom%zz%ind, moved_atom%znum%ind, moved_atom%atom_type, moved_atom%znum_r%ind, stat=istat)
        deallocate(psum_int, psum_int_sq, sum_int, sum_int_sq)
#ifdef DEBUG
        write(*,*) "I am core", myid, "and I am done with fem_update."
#endif
    end subroutine fem_update


    subroutine fem_accept_move()
    ! Accept the move.  The atom positions are already changed in the rotated
    ! models, so we only need to clear old_index and old_pos arrays for reuse.
        use mpi
        call fem_reset_old()
    end subroutine fem_accept_move


    subroutine fem_reset_old()
        use mpi
        integer :: i
        do i=myid+1, nrot, numprocs
            old_index(i)%nat = 0
            if(allocated(old_index(i)%ind)) deallocate(old_index(i)%ind)
            old_pos(i)%nat = 0
            if(allocated(old_pos(i)%pos)) deallocate(old_pos(i)%pos)
        enddo
    end subroutine fem_reset_old


    subroutine fem_reject_move(m, atom, xx_cur, yy_cur, zz_cur) !, iii)
    ! Reject the move. If the atom was simply moved, unmove it using old_pos and old_index.
        use mpi
        type(model), intent(in) :: m ! Just in because we undo the move elsewhere
        integer, intent(in) :: atom
        real, intent(in) :: xx_cur, yy_cur, zz_cur
        integer :: i, j, istat
        type(model) :: moved_atom

        ! Create a new model (moved_atom) with only one atom in it and put the
        ! position etc of the moved atom into it.
        allocate(moved_atom%xx%ind(1), moved_atom%yy%ind(1), moved_atom%zz%ind(1), &
            moved_atom%znum%ind(1), moved_atom%atom_type(1), moved_atom%znum_r%ind(1), &
            stat=istat)
        moved_atom%natoms = 1
        ! mn%xx%ind, etc have already been updated by random_move so these are the
        ! new, moved atom positions.
        moved_atom%xx%ind(1) = xx_cur
        moved_atom%yy%ind(1) = yy_cur
        moved_atom%zz%ind(1) = zz_cur
        moved_atom%znum%ind(1) = m%znum%ind(atom)
        moved_atom%znum_r%ind(1) = m%znum_r%ind(atom)
        moved_atom%lx = m%lx
        moved_atom%ly = m%ly
        moved_atom%lz = m%lz
        moved_atom%nelements = 1
        moved_atom%atom_type(1) = m%znum%ind(atom)
        moved_atom%rotated = .FALSE.

#ifdef DEBUG
        write(*,*) "Un-moving atom in rotated models"
#endif
        do i=myid+1, nrot, numprocs
#ifdef DEBUG
            write(*,*) "Model", i, "has old_index%nat=", old_index(i)%nat
#endif
            if(.not. old_index(i)%nat == 0) then

                call rotate_atom(rot(i,1), rot(i, 2), rot(i, 3), moved_atom, rot_atom, istat)
                call move_atom_in_rotated_model(atom,mrot(i),i)

                ! The saved intensity values must return to their old values
                do j=1, pa%npix
                    int_i(1:nk, j, i) = old_int(1:nk, j, i)
                    int_sq(1:nk, j, i) = old_int_sq(1:nk, j, i)
                enddo
            endif
        enddo
        call fem_reset_old()
    end subroutine fem_reject_move


    subroutine add_pos(p, xx, yy, zz, istat)
    ! Adds xx, yy, zz to p%ind and increments p%pos.
        type(pos_list), intent(inout) :: p
        real, intent(in) :: xx, yy,  zz
        integer, intent(out) :: istat
        real, dimension(:,:), allocatable :: scratch
        if (p%nat .GT. 0) then
             allocate(scratch(p%nat+1,3), stat=istat)
             if (istat /= 0) continue
             scratch(1:p%nat, 1:3) = p%pos
             p%nat = p%nat+1
             scratch(p%nat,1) = xx
             scratch(p%nat,2) = yy
             scratch(p%nat,3) = zz
             deallocate(p%pos)
             allocate(p%pos(p%nat,3), stat=istat)
             if (istat /= 0) continue
             p%pos = scratch
        else
             p%nat = 1
             allocate(p%pos(1,3), stat=istat)
             if (istat /= 0) continue
             p%pos(1,1) = xx
             p%pos(1,2) = yy
             p%pos(1,3) = zz
        endif
        call check_for_error(istat, 'Error allocating memory in add_pos.')
        if (allocated(scratch)) then
            deallocate(scratch)  ! added 3/18/09 pmv 
        endif
    end subroutine add_pos


    subroutine print_sampled_map(m, res)
        type(model), intent(in) :: m
        real, intent(in) :: res
        integer, dimension(:,:), allocatable :: map
        integer, dimension(:), allocatable :: sampled_atoms
        integer, pointer, dimension(:):: pix_atoms
        integer :: i, j, istat, x, y
        character(len=256) :: buffer
        character(len=2) :: str
        real, dimension(:), allocatable :: rr_a
        real, allocatable, dimension(:) :: rr_x, rr_y
        real :: sqrt1_2_res
        real :: x2, y2

        sqrt1_2_res = sqrt(0.5) * res

        allocate(sampled_atoms(m%natoms))
        sampled_atoms = 0

        allocate(map( ceiling(m%lx), ceiling(m%ly) ))
        map = 0

        write(*,*)
        write(*,*) "Each row and column below represents", m%lx/ceiling(m%lx), "Angstroms."
        write(*,*) "Dashes represent 0's (for easier viewing) and *'s represent numbers over 9."
        write(*,*) "Numbers indicate the number of atoms at that physical location in the model that are being sampled by a single femsim run (in the 2D projection)."

        do i=1, pa%npix
            call hutch_list_pixel_sq(m, pa%pix(i,1), pa%pix(i,2), pa%phys_diam, pix_atoms, istat)

            if(allocated(rr_x)) deallocate(rr_x)
            if(allocated(rr_y)) deallocate(rr_y)
            if(allocated(rr_a)) deallocate(rr_a)
            allocate( rr_x(size(pix_atoms)),rr_y(size(pix_atoms)), rr_a(size(pix_atoms)), stat=istat)

            do j=1, size(pix_atoms)
                x2=m%xx%ind(pix_atoms(j))-pa%pix(i,1)
                y2=m%yy%ind(pix_atoms(j))-pa%pix(i,2)
                x2=x2-m%lx*anint(x2/m%lx)
                y2=y2-m%ly*anint(y2/m%ly)
                rr_x(j) = ABS(x2)
                rr_y(j) = ABS(y2)
                rr_a(j)=sqrt(x2*x2 + y2*y2)

                if((rr_x(j).le.sqrt1_2_res) .and. (rr_y(j) .le.  sqrt1_2_res))then
                    sampled_atoms(pix_atoms(j)) = sampled_atoms(pix_atoms(j)) + 1
                    x = floor( ( m%xx%ind(pix_atoms(j)) + (m%lx/2.0) ) / ( m%lx / ceiling(m%lx) ) ) + 1
                    y = floor( ( m%yy%ind(pix_atoms(j)) + (m%ly/2.0) ) / ( m%ly / ceiling(m%ly) ) ) + 1
                    map(x,y) = map(x,y) + 1
                endif
            enddo
        enddo
        do i=1, ceiling(m%lx)
            buffer = ''
            do j=1, ceiling(m%ly)
                str = ''
                if(map(i,j) .eq. 0) then
                    write(str, "(A1)") "-"
                    buffer = trim(buffer)//str
                else if(map(i,j) .lt. 10 ) then
                    write(str, "(I1)") map(i,j)
                    buffer = trim(buffer)//str
                else
                    write(str, "(A1)") "*"
                    buffer = trim(buffer)//str
                endif
            enddo
            write(*,*) trim(buffer)
        enddo

        write(*,*)
    end subroutine print_sampled_map


    subroutine pixel_positions(xx, yy, il)
    ! Return the pixel(s) that encompass(es) position xx, yy in il.
        real, intent(in) :: xx, yy
        type(index_list), intent(out) :: il
        integer :: i, k

        if(allocated(il%ind)) deallocate(il%ind)
        il%nat = 0

        ! First count how big il should be.
        do i=1, pa%npix
            if( ( abs(pa%pix(i,1) - xx) .le. pa%phys_diam / 2.0 ) .and. &
                ( abs(pa%pix(i,2) - yy) .le. pa%phys_diam / 2.0 ) ) then
                il%nat = il%nat + 1
            endif
        enddo
        ! Now allocate il%ind and add the pixels.
        allocate(il%ind(il%nat))
        k = 1
        do i=1, pa%npix
            if( ( abs(pa%pix(i,1) - xx) .le. pa%phys_diam / 2.0 ) .and. &
                ( abs(pa%pix(i,2) - yy) .le. pa%phys_diam / 2.0 ) ) then
                il%ind(k) = i
                k = k + 1
            endif
        enddo
    end subroutine pixel_positions


end module fem_mod
