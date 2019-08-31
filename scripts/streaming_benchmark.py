#!/usr/bin/env python
import argparse
import os
from termcolor import colored, cprint
import shutil
import subprocess
import sys
import time

import dxpy
import util

from typing import Callable, Iterator, Union, Optional, List

######################################################################
## constants

userHomeDir = os.environ["HOME"]
baseDir = os.path.join(userHomeDir, "dxfs2_test")
dxTrgDir = os.path.join(baseDir, "dxCopy")
dxfs2TrgDir = os.path.join(baseDir, "dxfs2Copy")
mountpoint = os.path.join(baseDir, "MNT")

#dxDirOnProject = "correctness/large"
dxDirOnProject = "benchmarks"

######################################################################


def copy_file_from_dxfs2(fname : str) -> int:
    cprint("copying from a dxfs2 mount point", "blue")
    fullName = os.path.join(mountpoint, dxDirOnProject, fname)
    trgFile = os.path.join(dxfs2TrgDir, fname)
    startTime = time.time()
    subprocess.check_output(["cp", fullName, trgFile])
    endTime = time.time()
    return round(endTime - startTime)


def copy_file_with_dx_download(dxProj, fname : str) -> int:
    # download the platform directory with 'dx'
    cprint("copying with dx cat", "blue")
    fullName = os.path.join(dxDirOnProject, fname)
    trgFile = os.path.join(dxTrgDir, fname)

    startTime = time.time()
    subprocess.check_output(["dx",
                             "download",
                             dxProj.get_id() + ":/" + fullName,
                             "-o",
                             trgFile])
    endTime = time.time()

    return round(endTime - startTime)


def benchmark(dxProj):
    cprint("Clearing out directory {} for testing".format(baseDir), "blue")

    # clean and make fresh directories
    # Be careful here, NOT to erase the user home directory
    for d in [dxTrgDir, dxfs2TrgDir, mountpoint]:
        if d == userHomeDir:
            printf("Error, must not erase user home directory")
            os.exit(1)
        if os.path.exists(d):
            subprocess.check_output(["sudo", "rm", "-rf", d])
        os.makedirs(d)

    # download with dxfs2

    # Start the dxfs2 daemon in the background, and wait for it to initilize.
    cprint("Mounting dxfs2", "blue")
    subprocess.Popen(["sudo", "/go/bin/dxfs2", mountpoint, dxProj.get_id()],
                     close_fds=True)
    time.sleep(1)

    try:
        cprint("Discover the benchmark files", "blue")
        files = os.listdir(os.path.join(mountpoint, dxDirOnProject))
        print("files to stream: {}".format(files))

        for fname in files:
            dx_download_sec = copy_file_with_dx_download(dxProj, fname)
            dxfs2_sec = copy_file_from_dxfs2(fname)
            print("\t dxfs2(sec) \t dx-download(sec)")
            print("{}\t {} \t {}".format(fname, dxfs2_sec, dx_download_sec))
    finally:
        cprint("Unmounting dxfs2", "blue")
        subprocess.check_output(["sudo", "umount", mountpoint])


## Program entry point
def main():
    argparser = argparse.ArgumentParser(description="Tests for dxfs2 filesystem")
    argparser.add_argument("--verbose", help="Verbose outputs",
                           action="store_true", default=False)
    argparser.add_argument("--project", help="DNAx project to take data from",
                           default="dxfs2_test_data")
    args = argparser.parse_args()

    # some sanity checks
    dxProj = util.get_project(args.project)

    benchmark(dxProj)

if __name__ == '__main__':
    main()
