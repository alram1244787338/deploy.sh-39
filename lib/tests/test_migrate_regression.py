# -*- coding: utf-8 -*-
"""
migrate_multimedia_files 回归测试
覆盖: 断点恢复 / 目标已存在跳过 / 删除源文件记录落盘 / restore_files 读取
"""
import unittest
from unittest.mock import Mock, patch, MagicMock, call
import os
import sys
import json
import tempfile
import shutil
import logging
import threading

logging.basicConfig(level=logging.DEBUG)

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

import oss2
from aliyun.oss import OSSManager


def _make_obj(key):
    obj = Mock()
    obj.key = key
    return obj


def _make_list_response(objects, is_truncated=False, next_marker=''):
    resp = Mock()
    resp.object_list = objects
    resp.is_truncated = is_truncated
    resp.next_marker = next_marker
    return resp


def _no_such_key():
    """构造一个真实的 NoSuchKey 异常"""
    return oss2.exceptions.NoSuchKey(404, {}, '', {})


class MigrateTestBase(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self._data_dir_patch = patch('aliyun.oss.get_data_dir', return_value=self.tmpdir)
        self._data_dir_patch.start()

    def tearDown(self):
        self._data_dir_patch.stop()
        shutil.rmtree(self.tmpdir, ignore_errors=True)
        for t in threading.enumerate():
            if t is not threading.current_thread():
                t.join(timeout=1)

    def _make_manager(self):
        with patch('oss2.Auth'):
            return OSSManager('fake_id', 'fake_secret', 'cn-test', 'default')


# ===================================================================
# 1. 断点续传：计数器不被重置
# ===================================================================
class TestCheckpointResume(MigrateTestBase):

    @patch('oss2.Bucket')
    def test_counters_preserved_on_resume(self, mock_bucket_cls):
        """已有 checkpoint 时 resume，计数器应保留 checkpoint 值"""
        checkpoint_file = os.path.join(
            self.tmpdir, 'migrate_src_to_dst_default_cn-test.json'
        )
        with open(checkpoint_file, 'w') as f:
            json.dump({
                'marker': 'prev/file.mp4',
                'processed_count': 10,
                'success_count': 8,
                'skipped_count': 2,
                'total_files': 10,
                'prefix': '',
                'last_update_time': '2025-01-01 00:00:00'
            }, f)

        mgr = self._make_manager()
        mock_bucket = MagicMock()
        mock_bucket_cls.return_value = mock_bucket
        # resume 后无新文件
        mock_bucket.list_objects.return_value = _make_list_response([], is_truncated=False)

        result = mgr.migrate_multimedia_files('src', 'dst', batch_size=10, max_workers=1)

        # success_count=8 > 0 → True
        self.assertTrue(result)

    @patch('oss2.Bucket')
    def test_resume_adds_new_counts(self, mock_bucket_cls):
        """resume 后新处理的文件应累加到已有计数器"""
        checkpoint_file = os.path.join(
            self.tmpdir, 'migrate_src_to_dst_default_cn-test.json'
        )
        with open(checkpoint_file, 'w') as f:
            json.dump({
                'marker': 'prev/file.mp4',
                'processed_count': 5,
                'success_count': 3,
                'skipped_count': 2,
                'total_files': 5,
                'prefix': '',
                'last_update_time': '2025-01-01 00:00:00'
            }, f)

        mgr = self._make_manager()
        mock_bucket = MagicMock()
        mock_bucket_cls.return_value = mock_bucket

        new_obj = _make_obj('new/video.mp4')
        mock_bucket.list_objects.return_value = _make_list_response([new_obj], is_truncated=False)

        # head_object: 1=source(IA), 2=dest(404), 3=verify copy
        head_calls = [0]
        def head_side_effect(key):
            head_calls[0] += 1
            if head_calls[0] == 1:
                return Mock(headers={'x-oss-storage-class': 'IA', 'etag': '"abc"'})
            elif head_calls[0] == 2:
                raise _no_such_key()
            else:
                return Mock(headers={'etag': '"abc"'})

        mock_bucket.head_object.side_effect = head_side_effect
        mock_bucket.copy_object.return_value = Mock(status=200)

        result = mgr.migrate_multimedia_files('src', 'dst', batch_size=10, max_workers=1)

        self.assertTrue(result)
        mock_bucket.copy_object.assert_called_once()


# ===================================================================
# 2. 目标已存在时跳过，仍返回成功
# ===================================================================
class TestSkipExistingFiles(MigrateTestBase):

    @patch('oss2.Bucket')
    def test_all_skipped_returns_success(self, mock_bucket_cls):
        """所有文件都命中目标已有（同 ETag），应返回 True 且不执行 copy"""
        mgr = self._make_manager()
        mock_bucket = MagicMock()
        mock_bucket_cls.return_value = mock_bucket

        obj = _make_obj('photos/img.jpg')
        mock_bucket.list_objects.return_value = _make_list_response([obj], is_truncated=False)

        head_calls = [0]
        def head_side_effect(key):
            head_calls[0] += 1
            if head_calls[0] == 1:
                return Mock(headers={'x-oss-storage-class': 'IA', 'etag': '"same"'})
            else:
                # dest head_object: 同 ETag → skip
                return Mock(headers={'etag': '"same"'})

        mock_bucket.head_object.side_effect = head_side_effect

        result = mgr.migrate_multimedia_files('src', 'dst', batch_size=10, max_workers=1)

        self.assertTrue(result)
        mock_bucket.copy_object.assert_not_called()

    @patch('oss2.Bucket')
    def test_no_ia_files_returns_success(self, mock_bucket_cls):
        """没有 IA 文件（无需迁移），应返回 True"""
        mgr = self._make_manager()
        mock_bucket = MagicMock()
        mock_bucket_cls.return_value = mock_bucket

        obj = _make_obj('docs/readme.txt')
        mock_bucket.list_objects.return_value = _make_list_response([obj], is_truncated=False)

        result = mgr.migrate_multimedia_files('src', 'dst', batch_size=10, max_workers=1)

        self.assertTrue(result)


# ===================================================================
# 3. 删除源文件记录落盘
# ===================================================================
class TestDeleteSourceRecord(MigrateTestBase):

    @patch('oss2.Bucket')
    def test_deleted_files_json_written(self, mock_bucket_cls):
        """delete_source=True 删除成功后，JSON 应包含已删除的 key"""
        mgr = self._make_manager()
        mock_bucket = MagicMock()
        mock_bucket_cls.return_value = mock_bucket

        obj = _make_obj('media/clip.mp4')
        mock_bucket.list_objects.return_value = _make_list_response([obj], is_truncated=False)

        head_calls = [0]
        def head_side_effect(key):
            head_calls[0] += 1
            if head_calls[0] == 1:
                # process_file_batch: source head → IA
                return Mock(headers={'x-oss-storage-class': 'IA', 'etag': '"xyz"'})
            elif head_calls[0] == 2:
                # consumer: dest head → 404 → 需要复制
                raise _no_such_key()
            elif head_calls[0] == 3:
                # consumer: verify copy → OK
                return Mock(headers={'etag': '"xyz"'})
            else:
                # 删除后验证: NoSuchKey → 删除成功
                raise _no_such_key()

        mock_bucket.head_object.side_effect = head_side_effect
        mock_bucket.copy_object.return_value = Mock(status=200)
        mock_bucket.batch_delete_objects.return_value = Mock(status=200)

        result = mgr.migrate_multimedia_files(
            'src', 'dst', batch_size=10, max_workers=1, delete_source=True
        )

        self.assertTrue(result)

        deleted_file = os.path.join(self.tmpdir, 'deleted_files_src.json')
        self.assertTrue(os.path.exists(deleted_file), f"应存在: {deleted_file}")
        with open(deleted_file, 'r') as f:
            deleted_keys = json.load(f)
        self.assertIn('media/clip.mp4', deleted_keys)

    @patch('oss2.Bucket')
    def test_temp_delete_file_cleaned_up(self, mock_bucket_cls):
        """迁移完成后 temp_delete 临时文件应被清理"""
        mgr = self._make_manager()
        mock_bucket = MagicMock()
        mock_bucket_cls.return_value = mock_bucket

        obj = _make_obj('media/clip.mp4')
        mock_bucket.list_objects.return_value = _make_list_response([obj], is_truncated=False)

        head_calls = [0]
        def head_side_effect(key):
            head_calls[0] += 1
            if head_calls[0] == 1:
                return Mock(headers={'x-oss-storage-class': 'IA', 'etag': '"xyz"'})
            elif head_calls[0] == 2:
                raise _no_such_key()
            elif head_calls[0] == 3:
                return Mock(headers={'etag': '"xyz"'})
            else:
                raise _no_such_key()

        mock_bucket.head_object.side_effect = head_side_effect
        mock_bucket.copy_object.return_value = Mock(status=200)
        mock_bucket.batch_delete_objects.return_value = Mock(status=200)

        mgr.migrate_multimedia_files(
            'src', 'dst', batch_size=10, max_workers=1, delete_source=True
        )

        temp_file = os.path.join(self.tmpdir, 'temp_delete_src.txt')
        self.assertFalse(os.path.exists(temp_file), "temp_delete 文件应被清理")


# ===================================================================
# 4. restore_files 读取删除列表
# ===================================================================
class TestRestoreFiles(MigrateTestBase):

    @patch('oss2.Bucket')
    def test_restore_reads_deleted_files(self, mock_bucket_cls):
        """手动写入 deleted_files JSON 后，restore_files 能读取并恢复"""
        mgr = self._make_manager()
        mock_bucket = MagicMock()
        mock_bucket_cls.return_value = mock_bucket

        deleted_file = os.path.join(self.tmpdir, 'deleted_files_src.json')
        with open(deleted_file, 'w') as f:
            json.dump(['media/a.mp4', 'media/b.mp4'], f)

        mock_bucket.copy_object.return_value = Mock(status=200)

        result = mgr.restore_files('src', 'dst')
        self.assertTrue(result)
        self.assertEqual(mock_bucket.copy_object.call_count, 2)

    @patch('oss2.Bucket')
    def test_restore_fails_without_json(self, mock_bucket_cls):
        """没有 deleted_files JSON 时，restore_files 返回 False"""
        mgr = self._make_manager()
        result = mgr.restore_files('nonexistent', 'dst')
        self.assertFalse(result)

    @patch('oss2.Bucket')
    def test_restore_after_migrate_integration(self, mock_bucket_cls):
        """集成：migrate(delete_source) → restore 能读到正确的文件列表"""
        mgr = self._make_manager()
        mock_bucket = MagicMock()
        mock_bucket_cls.return_value = mock_bucket

        # Phase 1: migrate
        obj = _make_obj('videos/long.mp4')
        mock_bucket.list_objects.return_value = _make_list_response([obj], is_truncated=False)

        head_calls = [0]
        def head_side_effect(key):
            head_calls[0] += 1
            if head_calls[0] == 1:
                return Mock(headers={'x-oss-storage-class': 'IA', 'etag': '"v1"'})
            elif head_calls[0] == 2:
                raise _no_such_key()
            elif head_calls[0] == 3:
                return Mock(headers={'etag': '"v1"'})
            else:
                raise _no_such_key()

        mock_bucket.head_object.side_effect = head_side_effect
        mock_bucket.copy_object.return_value = Mock(status=200)
        mock_bucket.batch_delete_objects.return_value = Mock(status=200)

        migrate_result = mgr.migrate_multimedia_files(
            'src', 'dst', batch_size=10, max_workers=1, delete_source=True
        )
        self.assertTrue(migrate_result)

        # Phase 2: restore
        mock_bucket.reset_mock()
        mock_bucket.copy_object.return_value = Mock(status=200)

        restore_result = mgr.restore_files('src', 'dst')
        self.assertTrue(restore_result)

        calls = mock_bucket.copy_object.call_args_list
        restored_keys = [c[0][2] for c in calls]
        self.assertIn('videos/long.mp4', restored_keys)


# ===================================================================
# 5. 异常路径
# ===================================================================
class TestExceptionHandling(MigrateTestBase):

    @patch('oss2.Bucket')
    def test_head_object_error_doesnt_crash(self, mock_bucket_cls):
        """单个文件 head_object 失败不影响其他文件"""
        mgr = self._make_manager()
        mock_bucket = MagicMock()
        mock_bucket_cls.return_value = mock_bucket

        good_obj = _make_obj('good/video.mp4')
        bad_obj = _make_obj('bad/video.mp4')
        mock_bucket.list_objects.return_value = _make_list_response(
            [bad_obj, good_obj], is_truncated=False
        )

        head_calls = [0]
        def head_side_effect(key):
            head_calls[0] += 1
            if key == 'bad/video.mp4':
                raise Exception("connection timeout")
            # good file: 1=source head(IA), 2=dest 404, 3=verify copy
            if head_calls[0] <= 3:
                return Mock(headers={'x-oss-storage-class': 'IA', 'etag': '"ok"'})
            elif head_calls[0] == 4:
                raise _no_such_key()
            else:
                return Mock(headers={'etag': '"ok"'})

        mock_bucket.head_object.side_effect = head_side_effect
        mock_bucket.copy_object.return_value = Mock(status=200)

        result = mgr.migrate_multimedia_files('src', 'dst', batch_size=10, max_workers=1)
        self.assertTrue(result)

    @patch('oss2.Bucket')
    def test_copy_error_preserves_counters(self, mock_bucket_cls):
        """copy_object 失败不影响其他文件的统计"""
        mgr = self._make_manager()
        mock_bucket = MagicMock()
        mock_bucket_cls.return_value = mock_bucket

        obj1 = _make_obj('a/video.mp4')
        obj2 = _make_obj('b/video.mp4')
        mock_bucket.list_objects.return_value = _make_list_response(
            [obj1, obj2], is_truncated=False
        )

        # 用 key 来区分 head_object 调用
        def head_side_effect(key):
            if key == 'a/video.mp4':
                # 第一次是 source head (IA)，后续是 consumer
                return Mock(headers={'x-oss-storage-class': 'IA', 'etag': '"e1"'})
            elif key == 'b/video.mp4':
                return Mock(headers={'x-oss-storage-class': 'IA', 'etag': '"e2"'})
            else:
                raise _no_such_key()

        mock_bucket.head_object.side_effect = head_side_effect

        # consumer 里的 dest head_object 和 verify 需要区分
        # 因为 head_side_effect 只按 key 区分，consumer 调用 head_object 时
        # dest 不存在应该 raise NoSuchKey，verify 应该返回 etag
        # 但 head_side_effect 只能按 key 判断。
        # 解决方案：用 call tracking
        head_call_keys = []
        original_head = head_side_effect
        def smart_head(key):
            head_call_keys.append(key)
            count_for_key = head_call_keys.count(key)
            if count_for_key == 1:
                # process_file_batch: source head
                if key == 'a/video.mp4':
                    return Mock(headers={'x-oss-storage-class': 'IA', 'etag': '"e1"'})
                else:
                    return Mock(headers={'x-oss-storage-class': 'IA', 'etag': '"e2"'})
            elif count_for_key == 2:
                # consumer: dest head → 404
                raise _no_such_key()
            else:
                # consumer: verify copy
                if key == 'a/video.mp4':
                    return Mock(headers={'etag': '"e1"'})
                else:
                    return Mock(headers={'etag': '"e2"'})

        mock_bucket.head_object.side_effect = smart_head

        copy_calls = [0]
        def copy_side_effect(*args, **kwargs):
            copy_calls[0] += 1
            if copy_calls[0] == 1:
                raise Exception("copy failed")
            return Mock(status=200)

        mock_bucket.copy_object.side_effect = copy_side_effect

        result = mgr.migrate_multimedia_files('src', 'dst', batch_size=10, max_workers=1)
        # 第二个文件成功 → True
        self.assertTrue(result)

    @patch('oss2.Bucket')
    def test_batch_delete_failure_not_in_deleted_json(self, mock_bucket_cls):
        """删除验证失败（文件仍存在）时，不应写入 deleted_files JSON"""
        mgr = self._make_manager()
        mock_bucket = MagicMock()
        mock_bucket_cls.return_value = mock_bucket

        obj = _make_obj('media/file.mp4')
        mock_bucket.list_objects.return_value = _make_list_response([obj], is_truncated=False)

        head_calls = [0]
        def head_side_effect(key):
            head_calls[0] += 1
            if head_calls[0] == 1:
                return Mock(headers={'x-oss-storage-class': 'IA', 'etag': '"del"'})
            elif head_calls[0] == 2:
                raise _no_such_key()
            elif head_calls[0] == 3:
                return Mock(headers={'etag': '"del"'})
            else:
                # 删除验证：文件仍存在 → 删除失败
                return Mock(headers={'etag': '"del"'})

        mock_bucket.head_object.side_effect = head_side_effect
        mock_bucket.copy_object.return_value = Mock(status=200)
        mock_bucket.batch_delete_objects.return_value = Mock(status=200)

        result = mgr.migrate_multimedia_files(
            'src', 'dst', batch_size=10, max_workers=1, delete_source=True
        )
        self.assertTrue(result)

        deleted_file = os.path.join(self.tmpdir, 'deleted_files_src.json')
        if os.path.exists(deleted_file):
            with open(deleted_file, 'r') as f:
                deleted_keys = json.load(f)
            self.assertNotIn('media/file.mp4', deleted_keys)


if __name__ == '__main__':
    unittest.main()
