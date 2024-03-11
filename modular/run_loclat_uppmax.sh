#!/bin/bash -l
#SBATCH -A naiss2023-5-97
#SBATCH -p core -n 2
#SBATCH -t 10-00:00:00 
#SBATCH -J nf_loclat
#SBATCH -o /crex/proj/fume/nobackup/private/jay/squeezmeta/logs/20240311_loclat.log
#SBATCH -e /crex/proj/fume/nobackup/private/jay/squeezmeta/logs/20240311_loclat.err
#SBATCH --mail-user jay.hakansson@slu.se
#SBATCH --mail-type=FAIL,END

mamba activate SqueezeMeta
res_name="loclat_20240221_1M_subsamp"
run_name="loclat_20240311_1M_subsamp"
nextflow run main.nf -c uppmax.config -with-report /crex/proj/fume/nobackup/private/jay/squeezmeta/logs/${run_name}_report.html -with-timeline /crex/proj/fume/nobackup/private/jay/squeezmeta/logs/${run_name}_timeline.html --project "/crex/proj/fume/nobackup/private/jay/test_pipeline/${res_name}" --threads 8 --samples "/crex/proj/fume/nobackup/private/jay/squeezmeta/Loclat/Loclat.samples" --fastq "/crex/proj/fume/nobackup/private/jay/squeezmeta/Loclat/raw" --mean_cov_threshold 20 --nr_samps_threshold 5 --min_med_cov 20 --threads 12 -with-trace -resume
