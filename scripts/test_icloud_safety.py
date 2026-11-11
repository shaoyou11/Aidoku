from pathlib import Path
import subprocess,tempfile,os,plistlib,xml.etree.ElementTree as ET
root=Path(__file__).resolve().parents[1]
s=(root/'Aidoku/Core/Database/CoreDataManager.swift').read_text()
start=s.index('    private static func preserveLibraryBeforeFirstCloudSync() throws {')
end=s.index('\n    // TODO: clean this up',start)
f=s[start:end].replace('private static func','func').replace('let directory = FileManager.default.applicationSupportDirectory','let directory = testDirectory').replace('let model = NSPersistentCloudKitContainer(name: "Aidoku").managedObjectModel','let model = testModel')
fixture='''import Foundation
import CoreData
let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
let testModel = NSManagedObjectModel()
let entity = NSEntityDescription()
entity.name = "ReadingProgress"
entity.managedObjectClassName = "NSManagedObject"
let progress = NSAttributeDescription()
progress.name = "page"
progress.attributeType = .integer64AttributeType
entity.properties = [progress]
testModel.entities = [entity]
func open(_ url: URL) throws -> NSManagedObjectContext {
 let coordinator = NSPersistentStoreCoordinator(managedObjectModel: testModel)
 _ = try coordinator.addPersistentStore(type: .sqlite, at: url)
 let context = NSManagedObjectContext(.mainQueue)
 context.persistentStoreCoordinator = coordinator
 return context
}
'''+f+'''
// Fresh installs must not invent a backup or mutate any store.
try preserveLibraryBeforeFirstCloudSync()
assert(!FileManager.default.fileExists(atPath: testDirectory.appendingPathComponent("Before-iCloud/complete").path))
let source = try open(testDirectory.appendingPathComponent("Aidoku.sqlite"))
let record = NSEntityDescription.insertNewObject(forEntityName: "ReadingProgress", into: source)
record.setValue(42, forKey: "page")
try source.save()
// Keep the source open: the saved changes may still live in SQLite's WAL.
try preserveLibraryBeforeFirstCloudSync()
record.setValue(99, forKey: "page")
try source.save()
try preserveLibraryBeforeFirstCloudSync()
let copy = try open(testDirectory.appendingPathComponent("Before-iCloud/Aidoku.sqlite"))
let request = NSFetchRequest<NSManagedObject>(entityName: "ReadingProgress")
assert(try copy.fetch(request).first!.value(forKey: "page") as! Int == 42)
assert(try source.fetch(request).first!.value(forKey: "page") as! Int == 99)
print("PASS: initial copy includes committed WAL; repeated launch preserves original backup and current local progress; fresh install safe")
'''
# assert autoclosures cannot throw
fixture=fixture.replace('assert(try copy.fetch(request).first!.value(forKey: "page") as! Int == 42)','let saved = try copy.fetch(request)\nassert(saved.first!.value(forKey: "page") as! Int == 42)').replace('assert(try source.fetch(request).first!.value(forKey: "page") as! Int == 99)','let current = try source.fetch(request)\nassert(current.first!.value(forKey: "page") as! Int == 99)')
d = tempfile.mkdtemp(prefix='aidoku-cloud-safety-')
p=Path(d)/'test.swift';p.write_text(fixture)
env=os.environ|{'DEVELOPER_DIR':'/Applications/Xcode.app/Contents/Developer'}
subprocess.run(['xcrun','swift',str(p)],env=env,check=True)
ent=plistlib.loads((root/'PersonalSigning.entitlements').read_bytes())
assert ent['com.apple.developer.icloud-services']==['CloudKit','CloudDocuments']
model=ET.parse(root/'Aidoku/Core/Database/Aidoku.xcdatamodeld/0.9.xcdatamodel/contents')
cloud=model.find("configuration[@name='Cloud']")
entities={x.attrib['name'] for x in cloud}
assert {'LibraryManga','History','Chapter','Category','ReadingSession'}<=entities
for entity in model.findall('entity'):
 if entity.attrib['name'] not in entities:continue
 for a in entity.findall('attribute'):
  assert a.attrib.get('optional')=='YES' or any(k.startswith('default') for k in a.attrib),(entity.attrib['name'],a.attrib)
 for r in entity.findall('relationship'):
  assert r.attrib.get('optional')=='YES' and 'inverseName' in r.attrib,(entity.attrib['name'],r.attrib)
assert 'appendingPathComponent("Aidoku.sqlite")' in s
assert 'updateCloudConfiguration' not in s
print('PASS: CloudKit model optional/default attributes and inverse relationships; iCloud entitlements; retained live store path')
