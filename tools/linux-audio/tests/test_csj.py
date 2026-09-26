import pytest

from common.csj import (
    csj_reference_text,
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
遠く & トーク
%<EOT>
"""


def test_csj_parser_reads_time_speaker_and_surface():
    items = parse_csj_transcript(SAMPLE)
    assert len(items) == 4
    assert items[0].start_ms == 8805
    assert items[0].end_ms == 12085
    assert items[0].speaker == "L"
    assert items[0].surface_lines == (
        "質問させていただきます",
        "(F あの)",
    )


def test_csj_parser_preserves_overlap():
    items = parse_csj_transcript(SAMPLE)
    assert items[0].end_ms > items[1].start_ms
    assert items[2].end_ms > items[3].start_ms


def test_csj_parser_keeps_header_only_nonverbal_span():
    items = parse_csj_transcript(SAMPLE)
    assert items[2].speaker == "R"
    assert items[2].header_annotation == "<笑>"
    assert items[2].surface_lines == ()


def test_csj_parser_rejects_invalid_time_range():
    with pytest.raises(ValueError, match="time range"):
        parse_csj_transcript(
            "0001 00002.000-00001.000 L:\n"
        )


def test_csj_reference_can_keep_or_drop_fillers():
    items = parse_csj_transcript(SAMPLE)
    assert csj_reference_text(
        items[:2],
        keep_fillers=True,
    ) == "質問させていただきますあのうん"
    assert csj_reference_text(
        items[:2],
        keep_fillers=False,
    ) == "質問させていただきます"
