#cython: profile=True

import random
import numpy as np
from collections import OrderedDict

from .utilities import *

from indelpost.variant cimport Variant

from .consensus import make_consensus


random.seed(123)


cdef class Contig:
    def __cinit__(self, Variant target, list pileup, int basequalthresh, int mapqthresh, double low_consensus_thresh=0.7, int donwsample_lim=100):
        self.target = target
        self.pileup = pileup

        self.targetpileup = self.__preprocess(mapqthresh, donwsample_lim)

        if self.targetpileup:
            consensus = make_consensus(self.target, self.targetpileup, basequalthresh)
            if consensus:
                self.__make_contig(consensus[0], consensus[1], basequalthresh)
                self.failed = False
            else:
                self.qc_passed = False
                self.failed = True
        else:
            self.qc_passed = False
            self.failed = True


    def __preprocess(self, mapqthresh, donwsample_lim):
        targetpileup = [read for read in self.pileup if read is not None and read["is_target"]]
        self.mapq = 0

        self.splice_pattern = get_local_reference(self.target, targetpileup, window=50, unspliced=False, splice_pattern_only=True)
        
        self.is_target_right_aligned = sum(read.get("target_right_aligned", 0) for read in targetpileup)
        
        if not targetpileup:
            return targetpileup

        if len(targetpileup) > donwsample_lim:
            targetpileup = random.sample(targetpileup, donwsample_lim)

        self.mapq = np.percentile([read["mapq"] for read in targetpileup], 50)
        self.low_qual_mapping_rate = sum(read["mapq"] < mapqthresh for read in targetpileup) / len(targetpileup)

        return targetpileup


    def __make_contig(self, lt_consensus, rt_consensus, basequalthresh):
         
        self.__index_by_genome_coord(lt_consensus[0], rt_consensus[0])
        
        self.lt_reference_seq = ""
        self.lt_target_block_reference_seq = ""
        self.lt_consensus_seq = ""
        self.lt_target_block_consensus_seq = ""
        self.lt_consensus_scores = []
        self.lt_target_block_consensus_scores = []

        self.indel_seq = ""
        
        self.rt_reference_seq = ""
        self.rt_target_block_reference_seq = ""
        self.rt_consensus_seq = ""
        self.rt_target_block_consensus_seq = ""
        self.rt_consensus_scores = []
        self.rt_target_block_consensus_scores = []

        exon_start, exon_end = -np.inf, np.inf
        if self.splice_pattern:
            for exon in self.splice_pattern:
                if exon[0] <= self.target.pos <= exon[1]:
                    exon_start, exon_end = exon[0], exon[1]
        
        for k, v in self.contig_dict.items():
            if k < self.target.pos:
                self.lt_reference_seq += v[0]        
                self.lt_consensus_seq += v[1]
                self.lt_consensus_scores.extend([v[2]] * len(v[1]))
                if exon_start <= k:
                    self.lt_target_block_reference_seq += v[0]
                    self.lt_target_block_consensus_seq += v[1]
                    self.lt_target_block_consensus_scores.extend([v[2]] * len(v[1]))    

            elif k == self.target.pos:
                self.lt_reference_seq += v[0][0]
                self.lt_target_block_reference_seq += v[0][0]

                self.lt_consensus_seq += v[1][0]
                self.lt_target_block_consensus_seq += v[1][0]

                self.lt_consensus_scores.append(v[2])
                self.lt_target_block_consensus_scores.extend([v[2]])

                self.indel_seq = self.target.indel_seq
            elif k > self.target.pos:
                self.rt_reference_seq += v[0]
                self.rt_consensus_seq += v[1]
                self.rt_consensus_scores.extend([v[2]] * len(v[1]))
                if k <= exon_end:
                    self.rt_target_block_reference_seq += v[0]
                    self.rt_target_block_consensus_seq += v[1]
                    self.rt_target_block_consensus_scores.extend([v[2]] * len(v[1]))
                     
        self.start = lt_consensus[1]
        self.end = rt_consensus[1]

        self.__profile_non_target_variants()

        self.qc_passed = self.__qc()


    def __index_by_genome_coord(self, lt_index, rt_index):
        self.lt_genomic_index = lt_index
        self.rt_genomic_index = rt_index

        genome_indexed_contig = lt_index
        genome_indexed_contig.update(rt_index)
        self.contig_dict = OrderedDict(sorted(genome_indexed_contig.items()))


    def __profile_non_target_variants(self):
        non_target_variants = [
            Variant(self.target.chrom, k, v[0], v[1], self.target.reference)
            for k, v in self.contig_dict.items()
            if v[0] and v[0] != v[1] and k != self.target.pos
        ]
        self.non_target_indels = [var for var in non_target_variants if var.is_indel]
        self.mismatches = [var for var in non_target_variants if not var.is_indel]

        self.gaps = [
            str(len(var.indel_seq)) + var.variant_type for var in self.non_target_indels
        ]
        self.gaps.append(str(len(self.target.indel_seq)) + self.target.variant_type)


    def __qc(self):

        lt_n, lt_len = self.lt_consensus_seq.count("N"), len(self.lt_consensus_seq)
        rt_n, rt_len = self.rt_consensus_seq.count("N"), len(self.rt_consensus_seq)
        
        qc_stats ={}
        
        qc_stats["low_qual_base_frac"] = low_qual_fraction(self.targetpileup)
        
        qc_stats["clip_rate"] = sum(True for k, v in self.contig_dict.items() if not v[0]) / len(self.contig_dict)
        
        lt_n_proportion = lt_n / lt_len
        rt_n_proportion = rt_n / rt_len
        qc_stats["n_rate"] = (lt_n + rt_n) / (lt_len + rt_len)

        low_consensus_rate_lt = (
            sum(score < self.low_consensus_thresh for score in self.lt_consensus_scores) / lt_len
        )
        low_consensus_rate_rt = (
            sum(score < self.low_consensus_thresh for score in self.rt_consensus_scores) / rt_len
        )
       
        qc_stats["low_consensus_rate"] = (low_consensus_rate_lt * lt_len + low_consensus_rate_rt * rt_len) / (lt_len + rt_len)
        
        self.qc_stats = qc_stats

        if qc_stats["low_qual_base_frac"] > 0.2:
            return False
        elif qc_stats["clip_rate"] > 0.1:
            return False
        elif qc_stats["n_rate"] > 0.1:
            return False
        elif low_consensus_rate_lt > 0.2 or low_consensus_rate_rt > 0.2:
            return False
        else:
            return True

    
    def get_reference_seq(self, split=False):
        if self.failed:
            return None
        
        if split:
            if self.target.is_del:
                return self.lt_reference_seq, self.indel_seq, self.rt_reference_seq
            else:
                return  self.lt_reference_seq, "", self.rt_reference_seq
        else:
            refseq = (
                self.lt_reference_seq + self.indel_seq + self.rt_reference_seq
                if self.target.is_del
                else self.lt_reference_seq + self.rt_reference_seq
            )

            return refseq


    def get_contig_seq(self, split=False):
        if self.failed:
            return None
        
        if split:
            if self.target.is_ins:
                return self.lt_consensus_seq, self.indel_seq, self.rt_consensus_seq
            else:
                return self.lt_consensus_seq, "", self.rt_consensus_seq
        else:
            conseq = (
                self.lt_consensus_seq + self.indel_seq + self.rt_consensus_seq
                if self.target.is_ins
                else self.lt_consensus_seq + self.rt_consensus_seq
            )

            return conseq
