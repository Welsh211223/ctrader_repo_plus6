def test_imports():
    """Minimal smoke test so coverage has data."""
    import ctrader.app  # noqa: F401
    import ctrader.data_providers.coinspot_v2  # noqa: F401

    assert True
