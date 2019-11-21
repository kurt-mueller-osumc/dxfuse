#!/usr/bin/env python
import argparse
from collections import namedtuple
import dxpy
import json
import pprint
import os
import sys
import subprocess
from typing import Callable, Iterator, Union, Optional, List
from termcolor import colored, cprint
import time
from dxpy.exceptions import DXJobFailureError

# The list of instance types to test on. We don't want too many, because it will be expensive.
# We are trying to take a representative from small, medium, and large instances.
aws_ladder = {
    "small" : ["mem1_ssd1_x4"],
    "large" : ["mem1_ssd1_x4", "mem1_ssd1_x16", "mem3_ssd1_x32"]
}

azure_ladder = {
    "small" : ["azure:mem1_ssd1_x4"],
    "large" : ["azure:mem1_ssd1_x4", "azure:mem1_ssd1_x16", "azure:mem3_ssd1_x16"],
}

def lookup_applet(name, project, folder):
    wfgen = dxpy.bindings.search.find_data_objects(name= name,
                                                   folder= folder,
                                                   project= project.get_id(),
                                                   limit= 1)
    objs = [item for item in wfgen]
    if len(objs) == 0:
        raise RuntimeError("applet {} not found in folder {}".format(name, folder))
    if len(objs) == 1:
        oid = objs[0]['id']
        return dxpy.DXApplet(project=project.get_id(), dxid=oid)
    raise RuntimeError("sanity")

def wait_for_completion(jobs):
    print("awaiting completion ...")
    # wait for analysis to finish while working around Travis 10m console inactivity timeout
    noise = subprocess.Popen(["/bin/bash", "-c", "while true; do sleep 60; date; done"])
    try:
        for job in jobs:
            try:
                job.wait_on_done()
            except DXJobFailureError:
                raise RuntimeError("Executable {} failed".format(job.get_id()))
    finally:
        noise.kill()
    print("done")

def get_project(project_name):
    '''Try to find the project with the given name or id.'''

    # First, see if the project is a project-id.
    try:
        project = dxpy.DXProject(project_name)
        return project
    except dxpy.DXError:
        pass

    project = dxpy.find_projects(name=project_name, return_handler=True, level="VIEW")
    project = [p for p in project]
    if len(project) == 0:
        print('Did not find project {0}'.format(project_name), file=sys.stderr)
        return None
    elif len(project) == 1:
        return project[0]
    else:
        raise Exception('Found more than 1 project matching {0}'.format(project_name))


def launch_and_wait(project, bench_applet, instance_types):
    # Run the workflows
    jobs=[]
    print("Launching benchmark applet")
    for itype in instance_types:
        print("instance: {}".format(itype))
        job = bench_applet.run({},
                               project=project.get_id(),
                               instance_type=itype)
        jobs.append(job)
    print("executables: " + ", ".join([a.get_id() for a in jobs]))

    # Wait for completion
    wait_for_completion(jobs)
    return jobs


def extract_results(jobs):
    header = "instance-type, file size, dx cat (seconds), dxfuse (seconds)"
    print(header)
    for j in jobs:
        desc = j.describe()
        i_type = desc["systemRequirements"]["*"]["instanceType"]
        results = desc['output']['result']

        # skip the header
        measurements = results[1:]
        for line in measurements:
            parts = line.split(",")
            print("{},\t{},\t{},\t{}".format(i_type, parts[0], parts[2], parts[4]))

def run_benchmarks(dx_proj, instance_types):
    applet = lookup_applet("dxfuse_benchmark", dx_proj, "/applets")
    jobs = launch_and_wait(dx_proj, applet, instance_types)
    extract_results(jobs)

def run_correctness(dx_proj, instance_types):
    applet = lookup_applet("dxfuse_correctness", dx_proj, "/applets")
    launch_and_wait(dx_proj, applet, instance_types)

def main():
    argparser = argparse.ArgumentParser(description="Run benchmarks on several instance types for dxfuse")
    argparser.add_argument("--project", help="DNAnexus project",
                           default="dxfuse_test_data")
    argparser.add_argument("--test", help="which testing suite to run [benchmark, correctness]",
                           default="correctness")
    argparser.add_argument("--size", help="how large should the test be? [small, large]",
                           default="small")
    args = argparser.parse_args()
    dx_proj = get_project(args.project)

    # figure out which region we are operating in
    region = dx_proj.describe()["region"]
    scale = None
    if region.startswith("aws:"):
        scale = aws_ladder
    elif region.startswith("azure"):
        scale = azure_ladder
    else:
        raise Exception("unknown region {}".format(region))

    if args.size in scale.keys():
        instance_types = scale[args.size]
    else:
        print("Unknown size value {}".format(args.scale))
        exit(1)

    if args.test == "benchmark":
        run_benchmarks(dx_proj, instance_types)
    elif args.test == "correctness":
        run_correctness(dx_proj, instance_types)
    else:
        print("Unknown test {}".format(args.test))
        exit(1)

if __name__ == '__main__':
    main()
