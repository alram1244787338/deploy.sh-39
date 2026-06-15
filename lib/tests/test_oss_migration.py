# -*- coding: utf-8 -*-
"""migrate_multimedia_files / restore_files 的回归测试。

覆盖需求中的关键链路：
  1. 断点续传：已有 checkpoint 时计数器要累加，不能清零，且不重复处理 marker 之前的对象。
  2. 目标已存在同 ETag：算作“已处理成功”，不触发复制，整体返回成功。
  3. delete_source：实际删除源文件，并把已删除清单落盘到 deleted_files_file。
  4. restore_files：能读取上一步落盘的清单，把文件从目标桶恢复回源桶。
  5. 复制失败：保留断点文件以便续传/排查，整体返回失败。

测试用内存版 FakeBucket 模拟 OSS，不访问真实网络。
"""
import io
import json
import os
import shutil
import sys
import tempfile
import threading
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

# 保证可以 import aliyun.oss（conftest 已做同样处理，这里兼容单文件直跑）
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

import oss2  # 由 conftest 注入的替身或真实 SDK
from aliyun.oss import OSSManager


def _make_nosuchkey():
    """构造一个与真实/替身 oss2 都兼容的 NoSuchKey 异常实例。"""
    return oss2.exceptions.NoSuchKey(404, {}, '', {})


class FakeObj:
    def __init__(self, key):
        self.key = key


class FakeHead:
    def __init__(self, etag, storage_class='IA'):
        self.headers = {'x-oss-storage-class': storage_class, 'etag': f'"{etag}"'}


class FakeListResult:
    def __init__(self, object_list, is_truncated=False, next_marker=''):
        self.object_list = object_list
        self.is_truncated = is_truncated
        self.next_marker = next_marker


class FakeBucket:
    """内存版 OSS bucket，支持 list/head/copy/batch_delete。"""

    def __init__(self, name, store, registry):
        self.name = name
        self.store = store          # dict: key -> {'etag':, 'storage_class':}
        self.registry = registry    # dict: bucket_name -> FakeBucket（用于 copy 找源桶）
        self.copied_keys = []       # 记录本桶上发生的复制目标
        self.deleted_keys = []      # 记录本桶上发生的删除
        self.fail_copy_keys = set() # 命中则复制抛错，模拟复制失败

    def list_objects(self, prefix='', marker='', max_keys=1000):
        # OSS 语义：marker 为“从此键之后开始”，即排他
        keys = sorted(k for k in self.store if k.startswith(prefix) and k > marker)
        page = keys[:max_keys]
        is_truncated = len(keys) > max_keys
        next_marker = page[-1] if (is_truncated and page) else ''
        return FakeListResult([FakeObj(k) for k in page], is_truncated, next_marker)

    def head_object(self, key):
        if key not in self.store:
            raise _make_nosuchkey()
        info = self.store[key]
        return FakeHead(info['etag'], info.get('storage_class', 'IA'))

    def copy_object(self, src_bucket_name, src_key, dst_key, headers=None):
        if dst_key in self.fail_copy_keys:
            raise RuntimeError('simulated copy failure')
        src = self.registry[src_bucket_name]
        self.store[dst_key] = dict(src.store[src_key])
        self.copied_keys.append(dst_key)
        return object()

    def batch_delete_objects(self, keys):
        for k in keys:
            self.store.pop(k, None)
            self.deleted_keys.append(k)
        return object()

    def delete_object(self, key):
        self.store.pop(key, None)
        self.deleted_keys.append(key)
        return object()


class OSSMigrationTestBase(unittest.TestCase):
    PROFILE = 'default'
    REGION = 'region'

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix='oss_mig_test_')
        # 所有数据文件（断点 / 临时删除清单 / 已删除清单）都落到临时目录
        patcher = patch('aliyun.oss.get_data_dir', return_value=self.tmpdir)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.manager = OSSManager('fake_id', 'fake_secret', self.REGION, self.PROFILE)

    def tearDown(self):
        main_thread = threading.current_thread()
        for thread in threading.enumerate():
            if thread is not main_thread:
                thread.join(timeout=2)
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    # --- helpers -----------------------------------------------------------
    def _build_registry(self, source_name, source_store, dest_name, dest_store):
        registry = {}
        source = FakeBucket(source_name, source_store, registry)
        dest = FakeBucket(dest_name, dest_store, registry)
        registry[source_name] = source
        registry[dest_name] = dest
        return registry, source, dest

    def _patch_buckets(self, registry):
        bucket_patcher = patch('oss2.Bucket')
        auth_patcher = patch('oss2.Auth')
        mock_bucket = bucket_patcher.start()
        auth_patcher.start()
        self.addCleanup(bucket_patcher.stop)
        self.addCleanup(auth_patcher.stop)
        mock_bucket.side_effect = lambda auth, endpoint, name: registry[name]
        return mock_bucket

    def _checkpoint_path(self, source_name, dest_name):
        return os.path.join(
            self.tmpdir,
            f'migrate_{source_name}_to_{dest_name}_{self.PROFILE}_{self.REGION}.json'
        )

    def _deleted_files_path(self, source_name):
        return os.path.join(self.tmpdir, f'deleted_files_{source_name}.json')


class TestSkipExisting(OSSMigrationTestBase):
    def test_dest_same_etag_counts_as_success_without_copy(self):
        """目标已存在同 ETag 文件：不复制，但整体算成功。"""
        source_store = {'a.mp4': {'etag': 'X', 'storage_class': 'IA'}}
        dest_store = {'a.mp4': {'etag': 'X', 'storage_class': 'IA'}}
        registry, source, dest = self._build_registry(
            'src-skip', source_store, 'dst-skip', dest_store
        )
        self._patch_buckets(registry)

        result = self.manager.migrate_multimedia_files(
            'src-skip', 'dst-skip', batch_size=1, max_workers=1
        )

        self.assertTrue(result, "全部命中已存在时应返回成功")
        self.assertEqual(dest.copied_keys, [], "ETag 相同不应触发复制")
        self.assertIn('a.mp4', source.store)
        # 没有失败、没有扫描中断 => 断点文件应被清理
        self.assertFalse(os.path.exists(self._checkpoint_path('src-skip', 'dst-skip')))


class TestResumeFromCheckpoint(OSSMigrationTestBase):
    def test_resume_keeps_counters_and_skips_marker_prefix(self):
        """有 checkpoint 时应从 marker 之后续跑，且计数器累加而非清零。"""
        source_store = {
            'a.mp4': {'etag': '1', 'storage_class': 'IA'},
            'b.mp4': {'etag': '2', 'storage_class': 'IA'},
            'c.mp4': {'etag': '3', 'storage_class': 'IA'},
        }
        dest_store = {}
        registry, source, dest = self._build_registry(
            'src-res', source_store, 'dst-res', dest_store
        )
        self._patch_buckets(registry)

        # 预置断点：marker 已到 a.mp4，且此前已处理/复制 1 个文件
        checkpoint = {
            'marker': 'a.mp4',
            'processed_count': 1,
            'copied_count': 1,
            'skipped_count': 0,
            'failed_count': 0,
            'total_files': 1,
            'prefix': '',
            'last_update_time': '2026-06-15 00:00:00',
        }
        with open(self._checkpoint_path('src-res', 'dst-res'), 'w', encoding='utf-8') as f:
            json.dump(checkpoint, f)

        buf = io.StringIO()
        with redirect_stdout(buf):
            result = self.manager.migrate_multimedia_files(
                'src-res', 'dst-res', batch_size=1, max_workers=1
            )
        output = buf.getvalue()

        self.assertTrue(result)
        # marker='a.mp4' 之后只剩 b、c，应只复制这两个；a 不再处理
        self.assertEqual(sorted(dest.copied_keys), ['b.mp4', 'c.mp4'])
        self.assertNotIn('a.mp4', dest.store, "marker 之前的对象不应被重新复制")
        # 计数器累加：之前 1 + 本次 2 = 3，证明没有清零
        self.assertIn('3/3', output, f"成功计数应为累加值 3/3，实际输出:\n{output}")
        # 干净结束后断点被清理
        self.assertFalse(os.path.exists(self._checkpoint_path('src-res', 'dst-res')))


class TestDeleteSourcePersistsRecords(OSSMigrationTestBase):
    def test_delete_source_writes_deleted_files_and_restore_reads_it(self):
        """delete_source 删除源文件并落盘清单；restore_files 能据此恢复。"""
        source_store = {'v.mp4': {'etag': '9', 'storage_class': 'IA'}}
        dest_store = {}
        registry, source, dest = self._build_registry(
            'src-del', source_store, 'dst-del', dest_store
        )
        self._patch_buckets(registry)

        result = self.manager.migrate_multimedia_files(
            'src-del', 'dst-del', batch_size=1, max_workers=1, delete_source=True
        )

        self.assertTrue(result)
        # 复制到目标，且源文件已删除
        self.assertIn('v.mp4', dest.store)
        self.assertNotIn('v.mp4', source.store)

        # 已删除清单落盘且内容正确
        deleted_path = self._deleted_files_path('src-del')
        self.assertTrue(os.path.exists(deleted_path), "应生成已删除清单文件")
        with open(deleted_path, 'r', encoding='utf-8') as f:
            self.assertEqual(json.load(f), ['v.mp4'])

        # 临时待删除文件应被清理
        self.assertFalse(os.path.exists(os.path.join(self.tmpdir, 'temp_delete_src-del.txt')))

        # restore_files 读取清单，把文件从目标桶恢复回源桶
        restored = self.manager.restore_files('src-del', 'dst-del')
        self.assertTrue(restored)
        self.assertIn('v.mp4', source.store, "restore_files 应恢复已删除的源文件")


class TestCopyFailurePreservesCheckpoint(OSSMigrationTestBase):
    def test_copy_failure_returns_false_and_keeps_checkpoint(self):
        """复制失败时整体返回失败，并保留断点以便续传/排查。"""
        source_store = {'x.mp4': {'etag': '5', 'storage_class': 'IA'}}
        dest_store = {}
        registry, source, dest = self._build_registry(
            'src-fail', source_store, 'dst-fail', dest_store
        )
        dest.fail_copy_keys = {'x.mp4'}  # 复制必失败
        self._patch_buckets(registry)

        result = self.manager.migrate_multimedia_files(
            'src-fail', 'dst-fail', batch_size=1, max_workers=1
        )

        self.assertFalse(result, "存在复制失败时应返回失败")
        self.assertEqual(dest.copied_keys, [])
        # 失败时保留断点文件，供续传/排查
        self.assertTrue(
            os.path.exists(self._checkpoint_path('src-fail', 'dst-fail')),
            "复制失败后应保留断点文件"
        )


if __name__ == '__main__':
    unittest.main()
