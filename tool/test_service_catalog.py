import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch, MagicMock
from refresh_service_catalog import convert, refresh, SOURCE, NoRedirect, LIMIT

def raw(rows): return json.dumps(rows).encode()
class CatalogTests(unittest.TestCase):
    def test_metadata_only(self):
        result = convert(raw([['Example', {'domain':'EXAMPLE.test','contact':{'email':'private@example.test'},'notes':'not sender evidence'}]]), 1)
        self.assertEqual(result['services'], [{'id':'example.test','name':'Example','host':'example.test'}])
        self.assertNotIn('private', json.dumps(result))
        self.assertFalse(result['signatureVerified'])
    def test_invalid_and_conflict(self):
        for value in [b'\xff', b'{}', b'[]', b'x'*(LIMIT+1), raw([['Bad\nName',{'domain':'ok.test'}]]), raw([['Local',{'domain':'localhost'}]]), raw([['One',{'domain':'same.test'}],['Two',{'domain':'same.test'}]])]:
            with self.assertRaises((ValueError, UnicodeDecodeError)): convert(value, 1)
    def test_duplicates_and_stable_sort(self):
        result=convert(raw([['Z',{'domain':'z.test'}],['A',{'domain':'a.test'}],['A',{'domain':'a.test'}]]),1)
        self.assertEqual([s['id'] for s in result['services']],['a.test','z.test'])
    def test_failed_fetch_retains_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path=pathlib.Path(directory)/'catalog.json';path.write_bytes(b'original')
            with patch('urllib.request.OpenerDirector.open', side_effect=TimeoutError):
                with self.assertRaises(TimeoutError): refresh(str(path))
            self.assertEqual(path.read_bytes(), b'original')
    def test_refresh_success_and_atomic_failure_paths(self):
        for mode in ['success', 'shrink', 'malformed', 'replace-failure']:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                path=pathlib.Path(directory)/'catalog.json'
                original=json.dumps({'services':[{}]*10}).encode();path.write_bytes(original)
                count=7 if mode=='shrink' else 10
                payload=b'bad' if mode=='malformed' else raw([[str(i),{'domain':f's{i}.test'}] for i in range(count)])
                response=MagicMock();response.status=200;response.read.return_value=payload
                opener=MagicMock();opener.open.return_value.__enter__.return_value=response
                with patch('urllib.request.build_opener',return_value=opener):
                    if mode=='success':
                        self.assertEqual(refresh(str(path)),10)
                        self.assertEqual(len(json.loads(path.read_bytes())['services']),10)
                        response.read.assert_called_once_with(LIMIT+1)
                    elif mode=='replace-failure':
                        with patch('os.replace',side_effect=OSError):
                            with self.assertRaises(OSError):refresh(str(path))
                    else:
                        with self.assertRaises(ValueError):refresh(str(path))
                if mode!='success':self.assertEqual(path.read_bytes(),original)
                self.assertEqual([p.name for p in pathlib.Path(directory).iterdir()],['catalog.json'])
    def test_unicode_units_and_controls(self):
        for name in ['x'+chr(i)+'y' for i in [0x85,0x200b,0x200e,0x2028,0x2029,0x61c,0x110bd,0x1343f]]+['😀'*61,'\nName']:
            with self.assertRaises(ValueError):convert(raw([[name,{'domain':'ok.test'}]]),1)
        self.assertEqual(len(convert(raw([['😀'*60,{'domain':'ok.test'}]]),1)['services']),1)
    def test_output_limit_retains_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            path=pathlib.Path(directory)/'catalog.json';original=raw({'services':[{}],'fetchedAt':1,'sha256':'0'*64});path.write_bytes(original)
            response=MagicMock();response.status=200;response.read.return_value=raw([['Good',{'domain':'good.test'}]])
            opener=MagicMock();opener.open.return_value.__enter__.return_value=response
            with patch('urllib.request.build_opener',return_value=opener),patch('refresh_service_catalog.OUTPUT_LIMIT',1):
                with self.assertRaises(ValueError):refresh(str(path))
            self.assertEqual(path.read_bytes(),original)
    def test_real_opener_rejects_redirect(self):
        import urllib.request
        import urllib.error
        opener=urllib.request.build_opener(NoRedirect)
        handler=next(h for h in opener.handlers if isinstance(h,NoRedirect))
        request=urllib.request.Request(SOURCE)
        with self.assertRaises(ValueError):handler.http_error_302(request,MagicMock(),302,'redirect',{'location':'https://example.test'})
    def test_redirect_never_followed(self):
        with self.assertRaises(ValueError):NoRedirect().redirect_request(None,None,None,None,None,None)
if __name__ == '__main__':unittest.main()
