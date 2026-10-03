import pytest

from common.csj import (
    csj_reference_text,
    csj_speaker_reference,
    parse_csj_transcript,
)


SAMPLE = """%講演ID:D04M0041
%<SOT>
0003 00008.805-00012.085 L:
質問させていただきます & シツモンサセテイタダキマス
(F あの) & (F アノ)
0004 00009.417-00009.838 R:
(F うん) & (F <VN>)
0007 00013.250-00014.315 R:<笑>
0008 00013.698-00016.817 L:
理解には & リカイニワ
(D (? つ))遠く & (D (? ツ))トーク
(?) & (?)
%<EOT>
"""


def test_csj_parser_reads_time_speaker_and_surface():
    items = parse_csj_transcript(SAMPLE)
    assert len(items) == 4
    assert items[0].start_ms == 8805
    assert items[0].end_ms == 12085
    assert items[0].speaker == "L"
    assert items[0].nonverbal is None
    assert items[0].surface_lines == (
        "質問させていただきます",
        "(F あの)",
    )


def test_nonverbal_span_is_kept_by_parser_but_excluded_from_reference():
    items = parse_csj_transcript(SAMPLE)
    assert items[2].nonverbal == "<笑>"
    assert items[2].surface_lines == ()

    assert csj_speaker_reference(items) == [
        {"start_ms": 8805, "end_ms": 12085, "speaker_label": "L"},
        {"start_ms": 9417, "end_ms": 9838, "speaker_label": "R"},
        {"start_ms": 13698, "end_ms": 16817, "speaker_label": "L"},
    ]


def test_verbatim_keeps_fillers_and_content_drops_them():
    items = parse_csj_transcript(SAMPLE)
    assert csj_reference_text(items, keep_fillers=True) == (
        "質問させていただきますあのうん理解にはつ遠く"
    )
    assert csj_reference_text(items, keep_fillers=False) == (
        "質問させていただきます理解にはつ遠く"
    )


@pytest.mark.parametrize(
    ("text", "message"),
    [
        ("0001 00002.000-00001.000 L:\n", "time range"),
        ("stray line\n0001 00000.000-00001.000 L:\nあ & ア\n", "precedes"),
        ("0001 00000.000-00001.000 L:注記\nあ & ア\n", "header annotation"),
        ("0001 00000.000-00001.000 L:<笑>\nあ & ア\n", "non-verbal"),
        ("0001 00000.000-00001.000 L:\n", "no surface lines"),
        ("0001 00000.000-00001.000 L:\nあいう\n", "separator"),
        ("0001 00000.000-00001.000 L:\n(X あ) & (X ア)\n", "unrecognized"),
        ("0001 00000.000-00001.000 L:\n(F あ & (F ア\n", "unclosed"),
        ("0001 00000.000-00001.000 L:\nあ) & ア)\n", "unbalanced"),
        ("%comment only\n", "no utterances"),
    ],
)
def test_csj_parser_rejects_format_it_does_not_understand(text, message):
    with pytest.raises(ValueError, match=message):
        parse_csj_transcript(text)
