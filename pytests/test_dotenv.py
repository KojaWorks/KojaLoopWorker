"""The tiny .env loader: parses KEY=VALUE, skips comments/blanks, strips quotes,
and never clobbers an already-set env var."""
import os

from loopworker.__main__ import load_dotenv


def test_load_dotenv(tmp_path, monkeypatch):
    (tmp_path / ".env").write_text(
        "# a comment\n"
        "\n"
        'PATCH_PAT="pat_quoted"\n'
        "ANON=plain\n"
        "WITH_EQUALS=a=b=c\n"
        "ALREADY=from_file\n"
        "noequalshere\n"
    )
    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv("PATCH_PAT", raising=False)
    monkeypatch.delenv("ANON", raising=False)
    monkeypatch.setenv("ALREADY", "from_env")  # a real env var must win

    load_dotenv()

    assert os.environ["PATCH_PAT"] == "pat_quoted"   # quotes stripped
    assert os.environ["ANON"] == "plain"
    assert os.environ["WITH_EQUALS"] == "a=b=c"      # only split on the first =
    assert os.environ["ALREADY"] == "from_env"       # not overridden
