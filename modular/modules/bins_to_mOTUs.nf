/*
Clusters bins based on similarity.
Input is a directory containing bins and a file with bin-name, completeness and contamination.
Output is the name of the taxonomic classification of the bins (unless taxSort = root),
a tsv with which bins belong to which mOTU, and the bintable file with quality data for the bins.
*/
process bins_to_mOTUs {
    /*the conda part might be removed later. If for example SuperPang gets updated to run with the newest version
    of mOTUlizer this process doesn't need a separate environment */
    conda 'bioconda::mOTUlizer=0.3.2'
    publishDir "${params.project}/mOTUs", mode: "copy"
    input:
    path(tax_dir)
    output:
    tuple(env(group), path("*_mOTUs.tsv"), path("${tax_dir}/*.bintable"), emit: mOTUs_file) //maybe change name to better represent content
    path("*_similarities.txt", emit: simi_file)
    shell:
    '''
    #!/bin/bash
    group="!{tax_dir}"
    group=${group%"_bins"}
    echo $group
    mOTUlize.py --fnas !{tax_dir}/*.fa --checkm !{tax_dir}/*.bintable --MAG-completeness !{params.MAGcomplete} --MAG-contamination !{params.MAGcontam} --threads !{params.threads} --keep-simi-file ${group}_similarities.txt -o ${group}_mOTUs.tsv
    '''
}
