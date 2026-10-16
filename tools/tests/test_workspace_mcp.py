import importlib.util, json, pathlib, tempfile, unittest, os
spec=importlib.util.spec_from_file_location('workspace_mcp',pathlib.Path(__file__).parents[2]/'app/resources/workspace_mcp.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.tmp.name);self.folder=self.root/'sources';self.folder.mkdir()
        self.cache=self.root/'cache'
        self.ws=module.Workspace({'roots':[{'path':str(self.folder),'directory':True}],'level':'view','cache':str(self.cache),'extractor':'unused'})
    def tearDown(self): self.tmp.cleanup()
    def test_inventory_is_lazy_even_for_1500_pages(self):
        for i in range(15): (self.folder/('%02d.pdf'%i)).write_bytes(b'not opened during link')
        self.assertEqual(len(self.ws.list_files()),15);self.assertFalse(self.cache.exists())
    def test_outside_and_symlink_blocked(self):
        target=self.root/'outside.txt';target.write_text('private')
        (self.folder/'escape').symlink_to(target)
        for value in ('../outside.txt','escape',str(target)):
            with self.assertRaises(PermissionError):self.ws.read_document(value)
    def test_on_demand_cache_and_invalidation(self):
        path=self.folder/'notes.txt';path.write_text('value 247')
        first=json.loads(self.ws.read_document('notes.txt')[0]['text'])
        second=json.loads(self.ws.read_document('notes.txt')[0]['text'])
        self.assertFalse(first['cache_hit']);self.assertTrue(second['cache_hit'])
        path.write_text('value 386 changed')
        third=json.loads(self.ws.read_document('notes.txt')[0]['text'])
        self.assertFalse(third['cache_hit']);self.assertIn('386',third['text'])
    def test_view_exposes_no_mutations(self):
        self.assertEqual([t['name'] for t in self.ws.tools()],['list_files','read_document'])
        with self.assertRaises(PermissionError):self.ws.call('write_file',{'path':'notes.txt','content':'bad'})
    def test_writes_require_backup_and_restore_boundary(self):
        self.ws.manifest['level']='write'
        with self.assertRaises(PermissionError): self.ws.write_file('edit.txt',content='bad')
        backup=self.root/'backup';backup.mkdir()
        (backup/'complete.json').write_text(json.dumps({'roots':self.ws.manifest['roots'],'restored':False}))
        self.ws.manifest['backup']=str(backup)
        self.ws.write_file('edit.txt',content='modified')
        self.ws.write_file('new.txt',content='created')
        self.assertEqual((self.folder/'edit.txt').read_text(),'modified')
        self.ws.delete_file('new.txt');self.assertFalse((self.folder/'new.txt').exists())
        with self.assertRaises(PermissionError):self.ws.write_file('../outside',content='bad')
        (backup/'complete.json').write_text(json.dumps({'roots':self.ws.manifest['roots'],'restored':True}))
        with self.assertRaises(PermissionError):self.ws.delete_file('edit.txt')
if __name__=='__main__' :unittest.main()
