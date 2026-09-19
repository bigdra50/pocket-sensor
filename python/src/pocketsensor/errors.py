"""SDK が公開する例外。想定した失敗はここへ集約する。"""

from __future__ import annotations


class PocketSensorError(Exception):
    """pocketsensor SDK の例外の親。"""


class ConnectionFailed(PocketSensorError):
    """open で端末へつなげなかった。待ち受けが無い、USB に端末が無い、ハンドシェイクの失敗を含む。"""


class ConnectionLost(PocketSensorError):
    """端末との接続が切れた。session_id が変わった再接続も含む。"""


class ProtocolError(PocketSensorError):
    """端末が約束と違うメッセージを送ってきた。"""


class Unsupported(PocketSensorError):
    """端末や記録が、求められた操作やストリームに対応していない。"""


class ClockNotReady(PocketSensorError):
    """時計合わせのサンプルがまだ無く、HOST 時刻を求められない。"""
