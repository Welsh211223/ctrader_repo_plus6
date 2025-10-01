from ctrader.constraints import apply_qty_constraints, floor_to_step, meets_min_notional


def test_floor_to_step_and_apply_qty():
    assert floor_to_step(1.2349, 0.001) == 1.234
    assert apply_qty_constraints(0.00009, "buy", min_qty=0.0001, qty_step=0.0001) == 0.0
    assert apply_qty_constraints(1.2349, "buy", min_qty=None, qty_step=0.01) == 1.23


def test_meets_min_notional():
    assert meets_min_notional(50.0, 30.0) is True
    assert meets_min_notional(10.0, 30.0) is False
