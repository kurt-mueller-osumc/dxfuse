#!/bin/bash -e

######################################################################
## constants

projName="dxfuse_test_data"
dxDirOnProject="correctness"

baseDir="$HOME/dxfuse_test"
dxTrgDir="${baseDir}/dxCopy"
mountpoint="${baseDir}/MNT"

dxfuseDir="$mountpoint/$projName/$dxDirOnProject"
dxpyDir="${baseDir}/dxCopy/$dxDirOnProject"

######################################################################

function check_tree {
    tree -n $dxfuseDir -o dxfuse.org.txt
    tree -n $dxpyDir -o dxpy.org.txt

    # The first line is different, we need to get rid of it
    tail --lines=+2 dxfuse.org.txt > dxfuse.txt
    tail --lines=+2 dxpy.org.txt > dxpy.txt

    diff dxpy.txt dxfuse.txt > D.txt || true
    if [[ -s D.txt ]]; then
        echo "tree command was not equivalent"
        cat D.txt
        exit 1
    fi
    rm -f dxfuse*.txt dxpy*.txt D.txt
}

function check_ls {
    d=$(pwd)
    cd $dxfuseDir; ls -R > $d/dxfuse.txt
    cd $dxpyDir; ls -R > $d/dxpy.txt
    cd $d
    diff dxfuse.txt dxpy.txt > D.txt || true
    if [[ -s D.txt ]]; then
        echo "ls -R was not equivalent"
        cat D.txt
        exit 1
    fi
    rm -f dxfuse*.txt dxpy*.txt D.txt
}

function check_cmd_line_utils {
    d=$(pwd)

    cd $dxfuseDir
    files=$(find dxWDL_source_code -type f)
    cd $d

    for f in $files; do
        # we want to run these checks only on text files.
        if [[ $(file -b $f) != "ASCII TEXT" ]]; then
            continue
        fi

        # Ok, this is a text file
        echo $f

        dxfuse_f=$dxfuseDir/$f
        dxpy_f=$dxpyDir/$f

        # wc should return the same result
        wc < $dxfuse_f > 1.txt
        wc < $dxpy_f > 2.txt
        diff 1.txt 2.txt > D.txt || true
        if [[ -s D.txt ]]; then
            echo "wc for files $dxfuse_f $dxpy_f is not the same"
            cat D.txt
            exit 1
        fi

        # head
        head $dxfuse_f > 1.txt
        head $dxpy_f > 2.txt
        diff 1.txt 2.txt > D.txt || true
        if [[ -s D.txt ]]; then
            echo "head for files $dxfuse_f $dxpy_f is not the same"
            cat D.txt
            exit 1
        fi

        # tail
        tail $dxfuse_f > 1.txt
        tail $dxpy_f > 2.txt
        diff 1.txt 2.txt > D.txt || true
        if [[ -s D.txt ]]; then
            echo "tail for files $dxfuse_f $dxpy_f is not the same"
            cat D.txt
            exit 1
        fi
        rm -f 1.txt 2.txt D.txt
    done
}

function check_find {
    find $dxfuseDir -type f -name "*.conf" > 1.txt
    find $dxpyDir -type f -name "*.conf" > 2.txt

    # each line starts with the directory name. those are different, so we normliaze them
    sed -i "s/MNT/dxCopy/g" 1.txt
    sed -i "s/$projName//g" 1.txt
    sed -i "s/\/\//\//g" 1.txt

    sed -i "s/MNT/dxCopy/g" 2.txt
    sed -i "s/$projName//g" 2.txt
    sed -i "s/\/\//\//g" 2.txt


    # line ordering could be different
    sort 1.txt > 1.s.txt
    sort 2.txt > 2.s.txt

    diff 1.s.txt 2.s.txt > D.txt || true
    if [[ -s D.txt ]]; then
        echo "find, when looking for files *.conf, doesn't produce the same results"
        cat D.txt
    fi
}

function check_grep {
    grep --directories=skip -R "stream" $dxfuseDir/dxWDL_source_code/src > 1.txt
    grep --directories=skip -R "stream" $dxpyDir/dxWDL_source_code/src > 2.txt

    # each line starts with the directory name. those are different, so we normliaze them

    sed -i "s/MNT/dxCopy/g" 1.txt
    sed -i "s/$projName//g" 1.txt
    sed -i "s/\/\//\//g" 1.txt

    sed -i "s/MNT/dxCopy/g" 2.txt
    sed -i "s/$projName//g" 2.txt
    sed -i "s/\/\//\//g" 2.txt

    # line ordering could be different
    sort 1.txt > 1.s.txt
    sort 2.txt > 2.s.txt

    diff 1.s.txt 2.s.txt > D.txt || true
    if [[ -s D.txt ]]; then
        echo "grep -R 'stream' doesn't produce the same results"
        cat D.txt
        exit 1
    fi
}

# copy a bunch of files in parallel
function check_parallel_cat {
    top_dir="$mountpoint/$projName/reference_data"
    target_dir="/tmp/write_test_dir"
    TOTAL_NUM_FILES=3

    mkdir -p $target_dir
    all_files=$(find $top_dir -type f)

    # limit the number of files in the test
    num_files=0
    files=""
    for f in $all_files; do
        # limit the number of files in the test
        num_files=$((num_files + 1))
        files="$files $f"
        if [[ $num_files == $TOTAL_NUM_FILES ]]; then
            break
        fi
    done

    # copy the chosen files in parallel
    pids=()
    for f in $files; do
        echo "copying $f"
        b_name=$(basename $f)
        cat $f > $target_dir/$b_name &
        pids="$pids $!"
    done

    # wait for jobs to complete
    for pid in ${pids[@]}; do
        wait $pid
    done

    # compare resulting files
    echo "comparing files"
    for f in $files; do
        b_name=$(basename $f)
        diff $f $target_dir/$b_name
    done

    rm -r $target_dir
}

# copy a file and check that platform has the correct content
#
function check_file_write_content {
    local top_dir=$1
    local target_dir=$2
    local content="nothing much"
    local write_dir=$top_dir/$target_dir

    echo "write_dir = $write_dir"

    # create a small file through the filesystem interface
    echo $content > $write_dir/A.txt
    ls -l $write_dir/A.txt

    # wait for the file to achieve the closed state
    while true; do
        file_state=$(dx describe $projName:/$target_dir/A.txt --json | grep state | awk '{ gsub("[,\"]", "", $2); print $2 }')
        if [[ "$file_state" == "closed" ]]; then
            break
        fi
        sleep 2
    done

    echo "file is closed"
    dx ls -l $projName:/$target_dir/A.txt

    # compare the data
    content2=$(dx cat $projName:/$target_dir/A.txt)
    if [[ "$content" == "$content2" ]]; then
        echo "correct"
    else
        echo "bad content"
        echo "should be: $content"
        echo "found: $content2"
    fi
}

# copy files inside the mounted filesystem
#
function write_files {
    local top_dir=$1
    local target_dir=$2
    local write_dir=$top_dir/$target_dir

    echo "write_dir = $write_dir"
    ls -l $write_dir

    echo "copying large files"
    cp $top_dir/correctness/large/*  $write_dir/

    # compare resulting files
    echo "comparing files"
    files=$(find $top_dir/correctness/large -type f)
    for f in $files; do
        b_name=$(basename $f)
        diff $f $write_dir/$b_name
    done
}

# check that we can't write to VIEW only project
#
function write_to_read_only_project {
    ls $mountpoint/dxfuse_test_read_only
    (echo "hello" > $mountpoint/dxfuse_test_read_only/A.txt) >& cmd_results.txt || true
    result=$(cat cmd_results.txt)

    echo "result=$result"
    if [[  $result =~ "Operation not permitted" ]]; then
        echo "Correct, we should not be able to modify a project to which we have VIEW access"
    else
        echo "Incorrect, we managed to modify a project to which we have VIEW access"
        exit 1
    fi
}

# create directory on mounted FS
function create_dir {
    local top_dir=$1
    local write_dir=$2

    cd $top_dir
    mkdir $write_dir

    # copy files to new directory
    echo "copying small files"
    cp $top_dir/correctness/small/*  $write_dir

    # compare resulting files
    echo "comparing files"
    files=$(find $top_dir/correctness/small -type f)
    for f in $files; do
        b_name=$(basename $f)
        diff $f $write_dir/$b_name
    done

    echo "making empty new sub-directories"
    mkdir $write_dir/E
    mkdir $write_dir/F
    echo "catch 22" > $write_dir/E/Z.txt

    tree $top_dir/$write_dir
}

# create directory on mounted FS
function create_remove_dir {
    local flag=$1
    local top_dir=$2
    local write_dir=$3

    cd $top_dir
    mkdir $write_dir
    rmdir $write_dir
    mkdir $write_dir

    # copy files
    echo "copying small files"
    cp $top_dir/correctness/small/*  $write_dir/

    # compare resulting files
    echo "comparing files"
    files=$(find $top_dir/correctness/small -type f)
    for f in $files; do
        b_name=$(basename $f)
        diff $f $write_dir/$b_name
    done

    echo "making empty new sub-directories"
    mkdir $write_dir/E
    mkdir $write_dir/F
    echo "catch 22" > $write_dir/E/Z.txt

    tree $write_dir

    if [[ $flag == "yes" ]]; then
        echo "letting the files complete uploading"
        sleep 10
    fi
    dx ls -l $projName:

    echo "removing directory recursively"
    rm -rf $write_dir

    dx ls $projName:
}

# removing a non-empty directory fails
function rmdir_non_empty {
    local write_dir=$1

    mkdir $write_dir
    cd $write_dir

    mkdir E
    echo "permanente creek" > E/X.txt

    set +e
    rmdir E >& /dev/null
    rc=$?
    set -e
    if [[ $rc == 0 ]]; then
        echo "Error, removing non empty directory should fail"
        exit 1
    fi

    rm -rf $write_dir
}

# removing a non-existent directory fails
function rmdir_not_exist {
    local top_dir=$1
    cd $top_dir

    set +e
    rmdir E >& /dev/null
    rc=$?
    set -e
    if [[ $rc == 0 ]]; then
        echo "Error, removing non existent directory should fail"
        exit 1
    fi
}

# create an existing directory fails
function mkdir_existing {
    local write_dir=$1
    mkdir $write_dir

    set +e
    mkdir $write_dir >& /dev/null
    rc=$?
    set -e
    if [[ $rc == 0 ]]; then
        echo "Error, creating an existing directory should fail"
        exit 1
    fi

    rm -rf $write_dir
}

function file_create_existing {
    local write_dir=$1
    cd $write_dir

    echo "happy days" > hello.txt

    set +e
    (echo "nothing much" > hello.txt) >& /tmp/cmd_results.txt
    rc=$?
    set -e

    if [[ $rc == 0 ]]; then
        echo "Error, could modify an existing file"
        exit 1
    fi
    result=$(cat /tmp/cmd_results.txt)
    if [[ ( ! $result =~ "Permission denied" ) && ( ! $result =~ "Operation not permitted" ) ]]; then
        echo "Error, incorrect command results, writing to hello.txt"
        cat /tmp/cmd_results.txt

        echo "===== log ======="
        cat /var/log/dxfuse.log
        exit 1
    fi

    rm -f hello.txt
}

function file_remove_non_exist {
    local write_dir=$1
    cd $write_dir

    set +e
    (rm hello.txt) >& /tmp/cmd_results.txt
    rc=$?
    set -e

    if [[ $rc == 0 ]]; then
        echo "Error, could remove a non-existent file"
        exit 1
    fi
    result=$(cat /tmp/cmd_results.txt)
    if [[ ! $result =~ "No such file or directory" ]]; then
        echo "Error, incorrect command results"
        cat /tmp/cmd_results.txt
        exit 1
    fi

}

# Get all the DX environment variables, so that dxfuse can use them
echo "loading the dx environment"

# don't leak the token to stdout
#source environment >& /dev/null
rm -f ENV
dx env --bash > ENV
source ENV >& /dev/null

# clean and make fresh directories
for d in $dxTrgDir $mountpoint; do
    mkdir -p $d
done

# Start the dxfuse daemon in the background, and wait for it to initilize.
echo "Mounting dxfuse"
flags=""
#    if [[ $verbose != "" ]]; then
flags="-verbose 2"
#    fi
sudo -E /go/bin/dxfuse $flags $mountpoint dxfuse_test_data dxfuse_test_read_only &
dxfuse_pid=$!
sleep 2

#    echo "download recursively with dx download"
#    dx download --no-progress -o $dxTrgDir -r  dxfuse_test_data:/$dxDirOnProject
#
#    # do not exit immediately if there are differences; we want to see the files
#    # that aren't the same
#    diff -r --brief $dxpyDir $dxfuseDir > diff.txt || true
#    if [[ -s diff.txt ]]; then
#        echo "Difference in basic file structure"
#        cat diff.txt
#        exit 1
#    fi
#
#    # find
#    echo "find"
#    check_find
#
#    # grep
#    echo "grep"
#    check_grep
#
#    # tree
#    echo "tree"
#    check_tree
#
#    # ls
#    echo "ls -R"
#    check_ls
#
#    # find
#    echo "head, tail, wc"
#    check_cmd_line_utils

tree $mountpoint

echo "parallel downloads"
check_parallel_cat

# bash generate random alphanumeric string
target_dir=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)
dx rm -r $projName:/$target_dir >& /dev/null || true

echo "can write to a small file"
check_file_write_content "$mountpoint/$projName" $target_dir

echo "can write several files to a directory"
write_files "$mountpoint/$projName" $target_dir

echo "can't write to read-only project"
write_to_read_only_project

echo "create directory"
target_dir2=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)
dx rm -r $projName:/$target_dir2 >& /dev/null || true
create_dir "$mountpoint/$projName" $target_dir2

echo "create/remove directory"
target_dir3=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)
dx rm -r $projName:/$target_dir3 >& /dev/null || true
create_remove_dir "yes" "$mountpoint/$projName" $target_dir3
create_remove_dir "no" "$mountpoint/$projName" $target_dir3

echo "mkdir rmdir"
rmdir_non_empty "$mountpoint/$projName/sunny"
rmdir_not_exist "$mountpoint/$projName"
mkdir_existing  "$mountpoint/$projName/sunny"

echo "file create remove"
file_create_existing "$mountpoint/$projName"
file_remove_non_exist "$mountpoint/$projName"

echo "unmounting dxfuse"
cd $HOME
sudo umount $mountpoint

# wait until the filesystem is done running
wait $dxfuse_pid

for d in $target_dir $target_dir2 $target_dir3; do
    dx rm -r $projName:/$d >& /dev/null || true
done
