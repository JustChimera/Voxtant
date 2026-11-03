"""Local reference-based metrics. No network access and no model-as-reference shortcut."""
import math
import re
import unicodedata

NORMALIZATION = "nfkc-casefold-punctuation-separated-han-scalars-words-v1"


def is_han(c):
    return any(a <= ord(c) <= b for a, b in [(0x3400, 0x4DBF), (0x4E00, 0x9FFF), (0xF900, 0xFAFF), (0x20000, 0x323AF)])


def tokens(text):
    text = unicodedata.normalize("NFKC", text).casefold().replace("’", "'")
    result, word = [], []
    for i, c in enumerate(text):
        if is_han(c):
            if word:
                result.append("".join(word)); word = []
            result.append(c)
        elif c.isalnum() or (c == "'" and word and i + 1 < len(text) and text[i + 1].isalpha()):
            word.append(c)
        elif word:
            result.append("".join(word)); word = []
    if word:
        result.append("".join(word))
    return result


def edits(reference, hypothesis):
    # Keep counts, rather than averaging per-clip percentages with different denominators.
    prev = [(i, 0, i, 0) for i in range(len(hypothesis) + 1)]
    for i, a in enumerate(reference, 1):
        row = [(i, 0, 0, i)]
        for j, b in enumerate(hypothesis, 1):
            if a == b:
                row.append(prev[j - 1])
            else:
                sub = prev[j - 1]; ins = row[j - 1]; delete = prev[j]
                row.append(min((
                    (sub[0] + 1, sub[1] + 1, sub[2], sub[3]),
                    (ins[0] + 1, ins[1], ins[2] + 1, ins[3]),
                    (delete[0] + 1, delete[1], delete[2], delete[3] + 1),
                ), key=lambda item: item[0]))
        prev = row
    e, s, i, d = prev[-1]
    return {"errors": e, "substitutions": s, "insertions": i, "deletions": d,
            "reference_units": len(reference), "hypothesis_units": len(hypothesis),
            "rate": e / len(reference) if reference else None}


def measures(reference, hypothesis):
    ref, hyp = tokens(reference), tokens(hypothesis)
    return {
        "mer": edits(ref, hyp),
        "english_projection_wer": edits([x for x in ref if re.search('[a-z]', x)], [x for x in hyp if re.search('[a-z]', x)]),
        "han_projection_cer": edits([x for x in ref if len(x) == 1 and is_han(x)], [x for x in hyp if len(x) == 1 and is_han(x)]),
    }


def aggregate(rows):
    result = {}
    for key in ["mer", "english_projection_wer", "han_projection_cer"]:
        sums = {k: sum(row[key][k] for row in rows) for k in
                ["errors", "substitutions", "insertions", "deletions", "reference_units", "hypothesis_units"]}
        sums["rate"] = sums["errors"] / sums["reference_units"] if sums["reference_units"] else None
        result[key] = sums
    return result


def quantile(values, p):
    values = sorted(x for x in values if x is not None and math.isfinite(x))
    return values[max(0, math.ceil(len(values) * p) - 1)] if values else None


def disagreement(a, b):
    a, b = tokens(a), tokens(b)
    return edits(a, b)["errors"] / max(len(a), len(b), 1)


def review_flags(text, duration):
    """Triage signals only: never rewrite repeated speech or score without a reference."""
    flags = []
    units = tokens(text)
    if re.search(r"(.)\1{19,}", text):
        flags.append("long-character-repetition")
    if re.search(r"\b(\w+)(?:\s+\1){12,}\b", text.casefold()):
        flags.append("long-word-repetition")
    if duration > 0 and len(units) / duration > 30:
        flags.append("excessive-output-rate")
    if not text.strip():
        flags.append("empty-hypothesis")
    if re.search(r"[А-Яа-яЁё]", text):
        flags.append("possible-other-source-language")
    return flags
