/*
This process takes the SqueezeMeta output and downsamples the bam files to get even coverage between samples, in preparation for Variant Calling.
This is only done on the core contigs over a certain length because those are the ones used for variant calling.
Input: the results directory from SqueezeMeta.
Output: Since there is a possibility that no bams fit the minimum coverage and breadth criteria, this process might have no output or it will send
        a tuple with a fasta file of all contigs longer than 1000 bases from the input pangenome and a merged bam-file from all bams that passed the breadth
        and coverage criteria.
The downsampling shell code is modified from POGENOM's Input_pogenom pipeline by Anders Andersson and Luis F. Delgado
See here: https://github.com/EnvGen/POGENOM/blob/master/Input_POGENOM/src/cov_bdrth_in_dataset.sh
*/
process downsample_bams_merge {
    tag "no_label"
    input:
    tuple(val(pang_id), path(pang_sqm), path(core_fasta))
    output:
    tuple(path("${pang_sqm}_long_contigs.fasta"), path("${pang_sqm}_merged.bam"), optional: true, emit: ref_merged)
    shell:
    '''
    cont_len=1000 #TURN INTO PIPELINE PARAM?
    #Get total length of NBPs longer than ${cont_len}
    echo "Counting positions in the core fasta"
    positions=$(awk 'BEGIN{i=0}; {(length($0) >= '${cont_len}')} {i=i+length($0)} END {print i}' !{core_fasta})
    echo "The total length of NBPs longer than ${cont_len} in the core fasta is ${positions}"
    core=false
    if grep -q "core" !{core_fasta}; then
        echo "Identified as core genome"
        core=true
    else
        echo "Identified as a singlemOTU or consensus genome. Will use all contigs over ${cont_len}"
    fi
    
    #Create tmp bams, filter for contigs over ${cont_len} bases put reads aligning to them in tmp_bams
    echo "Creating tmp bams"
    mkdir tmp_bams
    for bam in !{pang_sqm}/data/bam/*.bam;
    do
	echo "Filtering ${bam} alignments for contig length and core contigs"
        #Filter to select only paired reads (-f 2) and avoids optical duplicates (-F 1024)
        samtools view -Sbh -F 1024 -q 20 --threads !{task.cpus} $bam > tmp_filtered.bam
        samtools index tmp_filtered.bam
        
        #names of contigs longer than ${cont_len} in first column, and the length of contig in second column
	if $core; then
	   echo "Identified as core genome"
	   samtools idxstats tmp_filtered.bam --threads !{task.cpus} | awk '$2 >= '${cont_len}' { print $0 }' | grep "core" > contigs.tsv
	else
	   samtools idxstats tmp_filtered.bam --threads !{task.cpus} | awk '$2 >= '${cont_len}' { print $0 }' > contigs.tsv
	fi
        awk ' { print $1, 1, $2} ' contigs.tsv > contigs.bed
        #create tmp bams
        bam_ID=$(basename $bam .bam)
        samtools view -b -L contigs.bed --threads !{task.cpus} tmp_filtered.bam > tmp_bams/${bam_ID}.bam
    done
    
    mkdir -p !{pang_sqm}_mergeable
    echo "Creating mpileup files and checking breadth and coverage."    
    #create mpileup files, col 4 is number of reads at one position
    for bam in tmp_bams/*.bam;
    do
        #mpileup command doesn't allow multithreading
        #-A for count orphans
        samtools mpileup -A -d 1000000 -Q 15 -a $bam > tmp.mpileup
    
        # ---- arguments
        mpileupfile=tmp.mpileup
        bamfile=$bam
        outbamfile=$(basename $bam bam)subsampled.bam #name of output
        mag=!{pang_sqm} #pangenome name
        mincov=!{params.min_median_cov}
        minbreadth=!{params.min_breadth}
        samplename=$(basename ${bam#"${mag}."} .bam)

        #--- Median coverage
        #col 4 has nr of reads mapped to position, only take positions where reads mapped, sort by numerical value, add to array,
        #take value in middle of array (or mean of two middle values if even nr of values) = median cov
        #Not 100% sure why 0 positions are excluded in Input_pogenom. Their paper does say that they do it purposefully though.
        #but assuming it's because they aren't actually used for variant calling and therefore irrelevant for the coverage and downsampling
        cov=$(cut -f4 $mpileupfile | grep -vw "0" | sort -n | awk ' { a[i++]=$1; } END { x=int((i+1)/2); if (x < (i+1)/2) print (a[x-1]+a[x])/2; else print a[x-1]; }')

        #---breadth
        non_zero=$(cut -f4 $mpileupfile | grep -cvw "0")
        breadth=$(echo $non_zero*100/$positions | bc -l )

        echo "Genome:" $mag "- Sample:" $samplename "Median_coverage of core:" $cov " breadth %:" $breadth

        #---selection of BAM files and downsample
        if (( $(echo "$breadth >= $minbreadth" | bc -l) )) && (( $(echo "$cov >= $mincov" | bc -l) )); then
            echo "Downsampling coverage to $mincov - Genome: $mag - Sample: $samplename "
            limite=$(echo "scale=3; $mincov/$cov" | bc )
            samp=$(echo "scale=3; ($limite)+10" | bc)
            samtools view -Sbh --threads !{task.cpus} -s $samp $bamfile | samtools sort -o !{pang_sqm}_mergeable/$outbamfile --threads !{task.cpus}
        fi
    done
    
    #Merge bam-files that pass the check, if more than one bam in mergeable/ #*/ what to do if no files?
    #thoughts if at least one file in mergeable, create new fasta with only long contigs
    echo "Checking mergeable"
    if [ -z "$(ls -A !{pang_sqm}_mergeable)" ]; then
         echo "No sample fit the alignment criteria. Skipping further analysis for !{pang_sqm}"
    else
        echo "Merging subsampled bams. and creating fasta of pangenome with only NBPs over ${cont_len} bases."
        ls !{pang_sqm}_mergeable/*.bam > bamlist.txt
        samtools merge -o !{pang_sqm}_merged.bam -b bamlist.txt --threads !{task.cpus}
        samtools index !{pang_sqm}_merged.bam --threads !{task.cpus}
        samtools idxstats !{pang_sqm}_merged.bam --threads !{task.cpus}| awk '$2 >= '${cont_len}' { print $0 }' > long_contigs.tsv
        awk '{ print $1 }' long_contigs.tsv > contig_names.tsv
        #seqtk doesn't allow multithreading
        seqtk subseq !{pang_sqm}/results/01.*.fasta contig_names.tsv > !{pang_sqm}_long_contigs.fasta
    fi
    #cleanup step
    rm -r tmp*
    '''

}
