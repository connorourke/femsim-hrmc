"""
This is a rewrite in python of the rotation calculations in FEMSIM.
It currently does not correctly reproduce the exact angles of rotation,
but it should correctly reproduce the number of rotations that will
be used given nphi, npsi, and ntheta.
"""

import sys
import math


def calculate_rotations(nphi, npsi, ntheta, verbose=True):
    dphi = 2*math.pi / nphi
    dpsi = math.pi / npsi

    rot = [[0.0 for j in range(3)] for i in range(nphi*npsi*ntheta)]

    num_rot = 1  # Start at 1 so the initial entires are set to 0,0,0
    for i in range(0, nphi):
        phi = i * dphi

        for j in range(0, npsi):
            psi = j * dpsi

            _ntheta = int(math.sin(psi)*ntheta) - 1
            try:
                dtheta = math.pi/_ntheta
            except ZeroDivisionError:
                pass

            for k in range(1, _ntheta):
                theta = k * dtheta
                rot[num_rot][0] = phi
                rot[num_rot][1] = psi
                rot[num_rot][2] = theta
                num_rot = num_rot + 1

    if verbose:
        for phi, psi, theta in rot[0:num_rot]:
            print('{0}  {1}  {2}'.format(phi, psi, theta))

    return rot[0:num_rot]


def main():
    nphi = 1
    npsi = 40
    ntheta = 20
    if len(sys.argv) == 4:
        nphi = int(sys.argv[1])
        npsi = int(sys.argv[2]) / 2
        ntheta = int(sys.argv[3])

    assert npsi % 2 == 0
    rots = calculate_rotations(nphi, npsi/2, ntheta, verbose=True)
    print("Number of rotations:", len(rots))



if __name__ == '__main__':
    main()
