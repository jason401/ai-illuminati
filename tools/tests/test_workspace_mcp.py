import importlib.util, json, pathlib, tempfile, unittest, os, zipfile
from unittest.mock import patch
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
    def test_office_images_are_on_demand_and_cached(self):
        p=self.folder/'draft.docx'
        with zipfile.ZipFile(p,'w') as z:
            z.writestr('word/document.xml','<document><p><t>Calibration 247 kPa</t></p></document>')
            z.writestr('word/media/image1.png',b'image data')
        self.ws.read_document('draft.docx')
        converted=json.dumps({'pages':[{'page':1,'text':'','image':'aW1hZ2U=','mime':'image/png'}]}).encode()
        with patch.object(module.subprocess,'check_output',return_value=converted) as extract:
            first=self.ws.read_document('draft.docx',images=True)
            second=self.ws.read_document('draft.docx',images=True)
            self.assertEqual(extract.call_count,1)
            self.assertEqual([b['type'] for b in first],['text','text','image'])
            self.assertTrue(json.loads(second[0]['text'])['cache_hit'])
    def test_pptx_requested_slide_order_and_notes(self):
        p=self.folder/'slides.pptx'
        with zipfile.ZipFile(p,'w') as z:
            z.writestr('ppt/presentation.xml','<p:presentation xmlns:p="urn:p" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldId r:id="second"/><p:sldId r:id="first"/></p:presentation>')
            z.writestr('ppt/_rels/presentation.xml.rels','<Relationships><Relationship Id="first" Target="slides/slide1.xml"/><Relationship Id="second" Target="slides/slide2.xml"/></Relationships>')
            z.writestr('ppt/slides/slide1.xml','<slide><t>ONE</t></slide>')
            z.writestr('ppt/slides/slide2.xml','<slide><t>TWO</t></slide>')
            z.writestr('ppt/slides/_rels/slide2.xml.rels','<Relationships><Relationship Type="notesSlide" Target="../notesSlides/notes.xml"/></Relationships>')
            z.writestr('ppt/notesSlides/notes.xml','<notes><t>NOTE 789</t></notes>')
        result=json.loads(self.ws.read_document('slides.pptx',start=1,end=1)[0]['text'])
        self.assertIn('TWO',result['text']);self.assertIn('NOTE 789',result['text']);self.assertNotIn('ONE',result['text'])
if __name__=='__main__' :unittest.main()
