from __future__ import annotations

import pytest

from pocketsensor.clock import ClockEstimator, ClockNotReady, ClockSample, ClockView


def test_symmetric_round_trip_recovers_exact_offset() -> None:
    # phone は 900s 進み、片道 0.05s、端末内 0.01s。ナノ秒へ直した値
    sample = ClockSample(t1=100_000_000_000, t2=1_000_050_000_000, t3=1_000_060_000_000, t4=100_110_000_000)
    assert sample.offset == pytest.approx(900_000_000_000.0)
    assert sample.rtt == pytest.approx(100_000_000)


def test_negative_rtt_is_rejected() -> None:
    est = ClockEstimator()
    with pytest.raises(ValueError):
        est.add(ClockSample(t1=100, t2=1000, t3=1000_500, t4=100))


def test_t4_before_t1_is_rejected() -> None:
    est = ClockEstimator()
    with pytest.raises(ValueError):
        est.add(ClockSample(t1=200, t2=100, t3=110, t4=150))


def test_equal_rtt_prefers_newer_sample() -> None:
    est = ClockEstimator()
    # rtt 1 ms、offset 0。そのあと rtt 1 ms、offset 5 ms。同じ rtt なら新しいほう。
    est.add(ClockSample(t1=0, t2=500_000, t3=500_000, t4=1_000_000))
    est.add(ClockSample(t1=10_000_000, t2=15_500_000, t3=15_500_000, t4=11_000_000))
    assert est.rtt_ns == 1_000_000
    assert est.offset_ns == pytest.approx(5_000_000.0)


def test_estimator_prefers_smallest_rtt() -> None:
    est = ClockEstimator(window=8)
    est.add(ClockSample(t1=0, t2=900_500, t3=900_500, t4=400))
    est.add(ClockSample(t1=1000, t2=901_025, t3=901_025, t4=1050))
    est.add(ClockSample(t1=2000, t2=901_900, t3=901_900, t4=2200))
    assert est.ready
    assert est.offset_ns == pytest.approx(900_000.0)
    assert est.rtt_ns == 50
    assert est.sample_count == 3


def test_window_drops_old_best() -> None:
    est = ClockEstimator(window=8)
    est.add(ClockSample(t1=0, t2=0, t3=0, t4=10))
    for i in range(8):
        t1 = 1000 * (i + 1)
        est.add(ClockSample(t1=t1, t2=t1 + 1_000_000, t3=t1 + 1_000_000, t4=t1 + 100))
    assert est.offset_ns == pytest.approx(1_000_000.0 - 50)
    assert est.sample_count == 9


def test_not_ready_raises() -> None:
    est = ClockEstimator()
    assert est.ready is False
    with pytest.raises(ClockNotReady):
        est.device_to_host(1)


def test_theil_sen_drift_and_device_to_host() -> None:
    est = ClockEstimator(window=8, max_adopted=64)
    # 1 秒ごとにオフセットが 10000 ns 増える = 10 ppm。rtt を減らして毎回採用する
    for i in range(5):
        t_mid = 1_000_000_000 * i
        offset = 1_000_000 + 10_000 * i
        rtt = 100 - 10 * i
        t1 = t_mid - rtt // 2
        t4 = t_mid + rtt // 2
        t2 = t_mid + offset
        t3 = t2
        est.add(ClockSample(t1=t1, t2=t2, t3=t3, t4=t4))
    assert est.drift == pytest.approx(1e-5, rel=1e-9)
    assert est.drift_ppm == pytest.approx(10.0, rel=1e-9)
    t_device = 10_000_000_000
    t_ref, offset_ref = est._adopted[-1]
    expected = t_device - (offset_ref + est.drift * ((t_device - offset_ref) - t_ref))
    assert est.device_to_host(t_device) == pytest.approx(expected)


def test_clock_view_reports_the_wall_offset_separately() -> None:
    host = ClockEstimator()
    wall = ClockEstimator()
    # 端末の wire 時刻は壁時計に anchor してある。単調時計とのずれは巨大で、壁時計とのずれだけが人に読める。
    host.add(ClockSample(1_000, 1_700_000_000_000_001_500, 1_700_000_000_000_001_500, 2_000))
    wall.add(ClockSample(10_000, 22_500, 22_500, 11_000))
    view = ClockView(host, wall)
    assert view.offset_ns == pytest.approx(1_700_000_000_000_000_000, rel=1e-12)
    assert view.wall_offset_ns == pytest.approx(12_000)
