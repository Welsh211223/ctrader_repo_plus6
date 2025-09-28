from ctrader.core import run


def test_smoke(capsys):
    run()
    captured = capsys.readouterr()
    assert "ctrader: core.run() placeholder" in captured.out
