from .variant import Variant
from .utilities import split_cigar, get_local_reference
from .localn import make_aligner, align, findall_indels


def find_by_equivalence(
    target,
    pileup,
    match_score,
    mismatch_penalty,
    gap_open_penalty,
    gap_extension_penalty,
):
    """Search indels equivalent to the target indel
    
    Args:
        target (Variant): target indel 
        pileup (list): a list of dictized read (dict)
    Returns:
        annoated pileup (list): a list of dictized read (dict) 
    """

    pileup = [is_target_by_equivalence(read, target) for read in pileup]

    target = seek_larger_gapped_aln(
        target,
        pileup,
        match_score,
        mismatch_penalty,
        gap_open_penalty,
        gap_extension_penalty,
    )

    return target, pileup


def is_target_by_equivalence(read, target):
    """Check if read contains an indel equivalent to target
    
    read (dict): dictized read
    target (Variant)
    """
    if read.get("is_target", False):
        return read
    else:
        read["is_target"] = False

    # trivial case
    if read["is_reference_seq"]:
        return read

    for indel in read[target.variant_type]:
        if target == indel[-1]:
            read["is_target"] = True

            # trim clipped bases
            lt_offset = read["start_offset"]
            read["lt_flank"] = indel[1]
            read["lt_ref"] = indel[4]
            read["lt_qual"] = indel[6]

            read["indel_seq"] = indel[2]

            rt_offset = read["end_offset"]
            read["rt_flank"] = indel[3]
            read["rt_ref"] = indel[5]
            read["rt_qual"] = indel[7]

            read["lt_cigar"], read["rt_cigar"] = split_cigar(
                read["cigar_string"], target.pos, read["read_start"]
            )

    return read


def get_most_centered_read(target, pileup):

    most_centered_read = None

    targetpileup = [read for read in pileup if read["is_target"]]

    if targetpileup:
        dist2center = [
            abs(
                0.5
                - (read["aln_end"] - target.pos) / (read["aln_end"] - read["aln_start"])
            )
            for read in targetpileup
        ]
        most_centered_read = targetpileup[dist2center.index(min(dist2center))]

    return most_centered_read


def seek_larger_gapped_aln(
    target,
    pileup,
    match_score,
    mismatch_penalty,
    gap_open_penalty,
    gap_extension_penalty,
):

    read = get_most_centered_read(target, pileup)

    if not read:
        return target

    read_seq = read["read_seq"]

    ref_seq, lt_len = get_local_reference(target, pileup)

    aln = align(
        make_aligner(ref_seq, match_score, mismatch_penalty),
        read_seq,
        gap_open_penalty,
        gap_extension_penalty,
    )

    genome_aln_pos = target.pos + 1 - lt_len + aln.reference_start

    indels = findall_indels(aln, genome_aln_pos, ref_seq, read_seq)

    if not indels:
        return target

    closest = min([abs(target.pos - indel["pos"]) for indel in indels])
    candidates = [
        indel
        for indel in indels
        if abs(target.pos - indel["pos"]) == closest
        and indel["indel_type"] == target.variant_type
    ]

    if candidates:
        candidate = candidates[0]
        if candidate["indel_type"] == "I":
            ref = candidate["lt_ref"][-1]
            alt = ref + candidate["indel_seq"]
        else:
            alt = candidate["lt_ref"][-1]
            ref = alt + candidate["del_seq"]

        candidate_var = Variant(
            target.chrom, candidate["pos"], ref, alt, target.reference
        )

        if (
            candidate_var.pos <= target.pos
            and target.indel_seq in candidate_var.indel_seq
        ):
            target = candidate_var

    return target
