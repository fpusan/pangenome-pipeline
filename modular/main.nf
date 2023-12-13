#!/usr/bin/env nextflow
/*
========================================================================================
Pipeline for pangenome intra-diversity analysis
========================================================================================
Modular attempt
----------------------------------------------------------------------------------------
*/

nextflow.enable.dsl=2
include { validateParameters; paramsHelp; paramsSummaryLog; fromSamplesheet } from "plugin/nf-validation"

// Print help message, supply typical command line usage for the pipeline
if (params.help) {
   log.info paramsHelp("nextflow run main.nf --project <project_name> --samples <tsv.samples> --fastq <path/to/dir> --threads <nr> \n\n  To get more info about a specific parameter write nextflow run main.nf --help <parameter_name>")
   log.info """\
   You can supply a config file with the parameters using -c. For more info see the usr_template.config or
   ${params.manifest.homePage}
   """

   exit 0
}

// Validate input parameters
validateParameters()

// Print summary of supplied parameters
log.info paramsSummaryLog(workflow)

//Check project parameter
def badChars = ["^","(",")","+", " ", "|"]
if ( params.project.findAll { a -> badChars.any { a.contains(it) } } ) {
	throw new Exception("Invalid project name. Special characters and whitespaces not allowed.")
}

if (workflow.resume == false) {
	//Workflow was not resumed, checking project dir
	Path projDir = new File(params.project).toPath()
	if (projDir.exists() == true) {
		throw new Exception("Project directory $params.project already exists, choose a new name or use the -resume flag. WARNING: Note that if you resume the wrong job, this might overwrite previous results.")
	}
}

// import modules
//maybe some of these should be the same file instead if they're always run together. Group them?
include { format_samples } from './modules/format_samples'
include { fastq_to_bins } from './modules/fastq_to_bins'
include { subsample_fastqs } from './modules/subsample_fastqs'
include { parse_taxonomies } from './modules/parse_taxonomies'
include { bins_to_mOTUs } from './modules/bins_to_mOTUs'
include { create_mOTU_dirs } from './modules/create_mOTU_dirs'
include { mOTUs_to_pangenome } from './modules/mOTUs_to_pangenome'
include { checkm_pangenomes } from './modules/checkm_pangenomes'
include { checkm2_pangenomes } from './modules/checkm2_pangenomes'
include { index_pangenomes } from './modules/index_pangenomes'
include { index_coreref } from './modules/index_coreref'
include { map_subset } from './modules/map_subset'
include { cov_to_pang_samples } from './modules/cov_to_pang_samples'
include { pang_to_bams } from './modules/pang_to_bams'
include { downsample_bams_merge } from './modules/downsample_bams_merge'
include { detect_variants } from './modules/detect_variants'
//include {  } from './modules/'


//Thoughts, I shouldn't have copies of the same processes, but instead run each workflow "that's needed". Meaning if I already have bins, I could skip the first one for example?
//actually it seems like I can just create the channels and it will only run the processes if there's something there to run it with!
//this would mean that you could mix raw data, assemblies, and bins I think. Wait, this won't work actually because we'll always have the things needed for fastq_to_bins
// https://nextflow-io.github.io/patterns/conditional-process/
workflow bins_mOTUs_pangenome {
    take:
    	samples_files
    	fastq_dir
    
    main:
    	if ( params.assembly == null && params.bins == null ) {
    	//if no assembly nor bins provided:    
    	/* Runs the fastq_to_bins process.
		first() to supply the fastq dir for each sample
    	*/
    	fastq_to_bins(samples_files, fastq_dir.first())
    	bins = fastq_to_bins.out.bins
    	bintable = fastq_to_bins.out.bintable
    	}
    	//if params.assembly = file that exists
    	if ( params.assembly != null && params.bins == null ) {
    	//create channels and see if the files exist
    	//assembly_to_bins()
    	bins = assembly_to_bins.out.bins
    	bintable = assembly_to_bins.out.bintable
    	}
    	//Expecting a path to a dir with dirs named after the samples
    	if ( params.bins != null && params.assembly == null ) {
    	//create channels, check if the dirs exist, and get name of dirs.
    	//These dirs need to have the same names as the samples that were used to create them.
    	Channel.fromPath('params.bins/*', type: "dir", checkIfExists: true) //*/
    		.map { [it.getSimpleName(), it] }
		.set { bin_dirs }
	
	samples_files
		.map { [it.getSimpleName(), it] }
		.set { samples_files }
    	
    	//combine the right samples file with the right bin dir
    	//and run SqueezeMeta
    	bins_parsing(samples_files.combine(bin_dirs, by: 0), fastq_dir.first())
    	bins = bins_parsing.out.bins
    	bintable = bins_parsing.out.bintable
   	}
   	else {
   	//throw an error here
   	error "Error: Either provide a path to a directory with assemblies using -assembly, or with bins using -bins, or only proivde the fastq dir and .samples file."
   	}
    
    	/*
    	Before running mOTUlizer, the checkM and GTDB-Tk outputs (bintables) need to be parsed.
    	All bintables and all bins from different samples need to be collected so the taxonomy_parser 
    	process can run once with all data.
    	*/

    	bintable.collect().set { all_bintables }
    	bins.collect().multiMap { it -> to_tax_parser: to_mOTU_dirs: it }.set { all_bins }
    
    	parse_taxonomies(all_bins.to_tax_parser, all_bintables) 
    
    	/*
    	Clustering of bins, if they've been presorted to lower taxonomic ranks this can spawn parallell processes
    	*/
    	bins_to_mOTUs(parse_taxonomies.out.tax_bin_dirs.flatten())

    	/*
    	Creating dirs for the mOTUs by sorting based on the mOTUlizer output,
    	so each mOTU directory has the correct bins.
    	*/
    	create_mOTU_dirs(bins_to_mOTUs.out.mOTUs_file, all_bins.to_mOTU_dirs)

    	/*
    	Running SuperPang, creating pangenomes. Transpose makes it so that each mOTU from the same grouping within
    	the taxonomy selection will be sent individually to the process together with the matching bintable.
    	*/
    	mOTUs_to_pangenome(create_mOTU_dirs.out.transpose())
    
    emit:
    	core_fasta = mOTUs_to_pangenome.out.core_fasta
    	NBPs_fasta = mOTUs_to_pangenome.out.NBPs_fasta
    
}

workflow map_and_detect_variants {
    take:
    fastq_dir
    single_samples
    core_fasta
    NBPs_fasta
    
    main:
    //Going to mutliple processes
    single_samples.multiMap { it -> to_subsamp: to_cov_pang: it }.set { single_samples }
    fastq_dir.multiMap { it -> to_subsamp: to_pang_to_bams: it }.set { fastq_dir }
    
    //Concatenating fastqs and subsampling for later mapping for each singles sample
    subsample_fastqs(single_samples.to_subsamp, fastq_dir.to_subsamp.first())
    
    /*
    Index genomes for read mapping
    */
    index_coreref(core_fasta)

    /*
    map subset reads to pangenome and get coverage information
    */
    map_subset(index_coreref.out.fasta_index_id.combine(subsample_fastqs.out.sub_reads))

    /*
    Using the coverage from the mapping, decides which reads "belong" to which pangenome and creates new .samples files
    */
    cov_to_pang_samples(map_subset.out.coverage.collect(),single_samples.to_cov_pang.collect(), subsample_fastqs.out.readcount.collect())

    /*
    Create keys to match right samples file to right NBPs fasta (from same pangenome) as input to pang_to_bams.
    */
    cov_to_pang_samples.out.pang_samples
		.flatten()
		.map { [it.getSimpleName(), it] }
		.set { pang_samples }

    NBPs_fasta
		.map { [it.getSimpleName(), it] }
		.set { NBPs_fasta }

    /*
    Using the generated samples files for the pangenome, the raw reads and the pangenome assembly to map reads using SqueezeMeta.
    */
    pang_to_bams(pang_samples.combine(NBPs_fasta, by: 0), fastq_dir.to_pang_to_bams.first())

    /*
    Checking the breadth and the coverage of bams on the pangenome/ref-genome. Downsampling to even coverage and merging into one bam-file.
    */
    downsample_bams_merge(pang_to_bams.out.pang_sqm)

    /*
    Running freebayes on the merged bam to get a filtered vcf file.
    */
    detect_variants(downsample_bams_merge.out.ref_merged)
    
}


workflow {
    /*The fastq_dir is needed for:
	- Formating the individual sample files
	- All of the entrypoints
    */
    Channel.fromPath(params.fastq, type: "dir", checkIfExists: true)
	    .multiMap { dir -> format: to_bins: to_variants: dir }.set { fastq_chan }
	    
    //File with which fastq files belong to which samples. Tab delimited with sample-name, fastq file name and pair.
    sam_chan = Channel.fromPath(params.samples, type: "file", checkIfExists: true)

    /*Runs the process that creates individual samples files and creates three output channels:
	- For Squeezemeta (fastq_to_bins process)
	- For the subsampling
	- For creating samples files to the pangenomes
    */
    format_samples(sam_chan, fastq_chan.format)
    format_samples.out.flatten().multiMap { it -> to_bins: to_variants: it }.set { single_samps }
    
    /*
    If the user provided a dir with reference genomes, the pipeline will will only run 
    the map_and_detect_variants workflow.
    */
    if ( params.ref_genomes != null ) {
        Channel.fromPath( ['{params.ref-genomes}/*.fa', '{params.ref-genomes}/*.fasta'],
        checkIfExists: true ).multiMap { it -> core: NBPs: it }.set { ref-gens }
        /*
        When using a reference genome we don't have core and consensus,
        therefore handling the reference as both.
        This means that the whole genome is used both for mapping a subset of the reads,
        and for the variance analysis.
        */
        map_and_detect_variants(fastq_chan.to_variants, single_samps.to_variants,
    			    ref-gens.core, ref-gens.NBPs)    
    }
    
    else {
    	/*
    	Optional workflow, runs if no reference genomes provided. Uses the raw reads/provided assembly/provided 		bins to create pangenomes
    	*/
    	bins_mOTUs_pangenome(single_samps.to_bins, fastq_chan.to_bins)
    
    	/*
    	This workflow maps a subset of the reads to each pangenome to estimate which would pass the coverage checks.
    	The samples that pass the initial coverage checks are then used as samples for the pangenome/ref genome for
    	variance analysis, by mapping the reads, estimating coverage and breadth, downsampling etc.
    	Creates VCF files. Will add so it also creates pogenom results.
    	*/
    	map_and_detect_variants(fastq_chan.to_variants, single_samps.to_variants,
    			    bins_mOTUs_pangenome.out.core_fasta, bins_mOTUs_pangenome.out.NBPs_fasta)
    	}
    	
    //It should be possible to add a message for when the pipeline finishes.
    
}
