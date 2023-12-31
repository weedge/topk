#!/bin/bash
source ./function.sh

#"Exit immediately if a simple command exits with a non-zero status."
set -e

doc_cn=`expr $RANDOM % 10 + 1`
doc_size=`expr $RANDOM % 128 + 1`
file="docs.txt"
[ -n "$1" ] && doc_cn=$1
[ -n "$2" ] && doc_size=$2
[ -n "$3" ] && file=$3

mkdir -p testdata

rm -f ./testdata/$file
for ((i=1;i<=$doc_cn;i++)); do
    line=""
    for ((j=1;j<=$doc_size;j++)); do
        random=`expr $RANDOM % 1000000 + 1`;
        line=${line}"$random, "
        [ $j -eq $doc_size ]  && line=${line}"$random"
    done
    #echo -e "${line}" >> ./testdata/$file
    echo -e "${line}" | sort_line_with_gawk_asort >> ./testdata/$file
    #echo -e "${line}" | sort_line_with_awk_bubble >> ./testdata/$file
    #sort_line_with_bubble $line >> ./testdata/$file
done
