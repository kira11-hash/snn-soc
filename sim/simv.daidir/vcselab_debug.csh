#!/bin/csh -f

cd /home/chenqingan/Desktop/project/SoCDesign/sim

#This ENV is used to avoid overriding current script in next vcselab run 
setenv SNPS_VCSELAB_SCRIPT_NO_OVERRIDE  1

/opt/Synopsys/vcs_green/vcs-2021.09-sp2/linux64/bin/vcselab $* \
    -o \
    simv \
    -nobanner \

cd -

