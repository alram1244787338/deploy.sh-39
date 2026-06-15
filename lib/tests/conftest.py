# -*- coding: utf-8 -*-
import pytest
import os
import sys

# 添加项目根目录到 Python 路径
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

# 若环境未安装真实的 oss2 SDK，则注入一个轻量替身，保证测试可被导入与运行。
# 测试通过 unittest.mock.patch 替换 oss2.Bucket / oss2.Auth，因此替身仅需提供
# 可调用对象与一套真实的异常类（生产代码会 except oss2.exceptions.NoSuchKey）。
try:  # pragma: no cover - 真实 SDK 存在时直接使用
    import oss2  # noqa: F401
except ImportError:  # pragma: no cover - 仅在缺少 SDK 的环境生效
    import types
    from unittest.mock import MagicMock

    oss2_stub = types.ModuleType('oss2')

    class _OssError(Exception):
        """模拟 oss2 的异常基类，构造签名与真实 SDK 兼容 (status, headers, body, details)。"""

    exceptions = types.ModuleType('oss2.exceptions')
    for _name in (
        'OssError', 'ClientError', 'ServerError', 'RequestError',
        'NoSuchKey', 'NoSuchBucket', 'BucketNotEmpty',
        'NoSuchTagSet', 'NoSuchBucketPolicy',
    ):
        setattr(exceptions, _name, type(_name, (_OssError,), {}))

    models = types.ModuleType('oss2.models')
    models.BucketLifecycle = MagicMock(name='BucketLifecycle')

    oss2_stub.exceptions = exceptions
    oss2_stub.models = models
    oss2_stub.Auth = MagicMock(name='Auth')
    oss2_stub.Bucket = MagicMock(name='Bucket')
    oss2_stub.Service = MagicMock(name='Service')
    oss2_stub.ObjectIterator = MagicMock(name='ObjectIterator')
    oss2_stub.BucketIterator = MagicMock(name='BucketIterator')

    sys.modules['oss2'] = oss2_stub
    sys.modules['oss2.exceptions'] = exceptions
    sys.modules['oss2.models'] = models
