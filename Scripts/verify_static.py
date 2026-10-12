#!/usr/bin/env python3
"""Dependency-free structural checks. This is NOT Swift compilation or iOS QA."""
import calendar, datetime as dt, json, plistlib, re, struct, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
passed=[]
def check(condition, message):
    if not condition: raise AssertionError(message)
    passed.append(message)
# Parse the actual delivered OpenStep property list, not just its manifest.
source=(ROOT/'LocalChecklist.xcodeproj/project.pbxproj').read_text()
tokens=re.findall(r'"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+', re.sub(r'//[^\n]*','',source))
pos=0
def parse():
    global pos
    token=tokens[pos];pos+=1
    if token=='{':
        result={}
        while tokens[pos]!='}':
            key=parse();assert tokens[pos]=='=';pos+=1
            result[key]=parse();assert tokens[pos]==';';pos+=1
        pos+=1;return result
    if token=='(':
        result=[]
        while tokens[pos]!=')':
            result.append(parse())
            if tokens[pos]==',':pos+=1
        pos+=1;return result
    return json.loads(token) if token.startswith('"') else token
project=parse();check(pos==len(tokens),'PBX OpenStep structure parses completely')
objects=project['objects'];check(project['rootObject'] in objects,'PBX root object exists')
for object_id,value in objects.items():
    check(len(object_id)==24 and all(x in '0123456789ABCDEF' for x in object_id),f'PBX ID valid: {object_id}')
    for key in ['fileRef','productReference','mainGroup','productRefGroup','buildConfigurationList','containerPortal','target','targetProxy','baseConfigurationReference','remoteGlobalIDString']:
        if key in value:check(value[key] in objects,f'{value["isa"]}.{key} resolves')
    for key in ['children','files','buildPhases','dependencies','buildConfigurations','targets']:
        for reference in value.get(key,[]):check(reference in objects,f'{value["isa"]}.{key} resolves')
refs={k:v for k,v in objects.items() if v['isa']=='PBXFileReference'}
for ref in refs.values():
    if ref.get('sourceTree')=='<group>':check((ROOT/ref['path']).exists(),f'Referenced path exists: {ref["path"]}')
def target_sources(name):
    target=next(v for v in objects.values() if v['isa']=='PBXNativeTarget' and v['name']==name)
    phase=next(objects[x] for x in target['buildPhases'] if objects[x]['isa']=='PBXSourcesBuildPhase')
    return [refs[objects[x]['fileRef']]['path'] for x in phase['files']]
for name,folders,main_count in [('LocalChecklist',['App','Shared'],1),('LocalChecklistWidgets',['Widgets','Shared'],1),('LocalChecklistTests',['Tests'],0)]:
    files=target_sources(name)
    expected=sorted(str(p.relative_to(ROOT)) for folder in folders for p in (ROOT/folder).glob('*.swift'))
    if name=='LocalChecklistWidgets': expected=sorted(expected+['App/LocalNotificationScheduler.swift'])
    if name=='LocalChecklist': expected+=sorted(str(p.relative_to(ROOT)) for p in (ROOT/'Sync').glob('*.swift'))
    check(sorted(files)==expected,f'{name}: complete, unique source membership')
    check(sum((ROOT/p).read_text().count('@main') for p in files)==main_count,f'{name}: correct @main count')
check(target_sources('LocalChecklist-iPhone') == target_sources('LocalChecklist'), 'Standalone app uses the same app sources')
check(target_sources('LocalChecklist-iPhoneTests') == target_sources('LocalChecklistTests'), 'Standalone app runs the same native tests')
phone=next(v for v in objects.values() if v['isa']=='PBXNativeTarget' and v['name']=='LocalChecklist-iPhone')
check(not phone['dependencies'], 'Standalone app does not depend on the widget')
check(not any(objects[p]['isa']=='PBXCopyFilesBuildPhase' for p in phone['buildPhases']), 'Standalone app embeds no widget')
plist_paths=list((ROOT/'Config').glob('*.plist'))+list((ROOT/'Config').glob('*.entitlements'))+[ROOT/'Resources/PrivacyInfo.xcprivacy']
plists={p.name:plistlib.loads(p.read_bytes()) for p in plist_paths}
check(plists['iPhone.entitlements']=={}, 'Standalone app requires no App Groups capability')
check(plists['App.entitlements']['com.apple.security.application-groups']==plists['Widget.entitlements']['com.apple.security.application-groups'],'Both entitlements use the same App Group variable')
check(plists['App-Info.plist']['AppGroupIdentifier']==plists['Widget-Info.plist']['AppGroupIdentifier'],'App Group Info keys match')
check(plists['Widget-Info.plist']['NSExtension']['NSExtensionPointIdentifier']=='com.apple.widgetkit-extension','Widget extension point is correct')
check('NSMicrophoneUsageDescription' in plists['App-Info.plist'] and 'NSSpeechRecognitionUsageDescription' in plists['App-Info.plist'],'Speech/microphone usage descriptions exist')
check(plists['PrivacyInfo.xcprivacy']['NSPrivacyTracking'] is False,'Privacy manifest declares no tracking')
check('UIApplicationSceneManifest' in plists['App-Info.plist'],'SwiftUI scene manifest exists')
for name in ['App.entitlements','Mac.entitlements','Widget.entitlements','MacWidget.entitlements']:
    check(not any('icloud' in key.lower() for key in plists[name]),f'{name}: no cloud capability')
check('CloudKitContainerIdentifier' not in plists['App-Info.plist'] and 'CloudKitEnvironment' not in plists['App-Info.plist'],'No cloud container/runtime environment configuration')
check(plists['App-Info.plist']['NSBonjourServices']==['_lc-checklist._tcp'],'Bonjour discovery service is explicit')
check(bool(plists['App-Info.plist']['NSLocalNetworkUsageDescription']),'Local network purpose is disclosed')
check(plists['Mac.entitlements']['com.apple.security.app-sandbox'] is True,'Mac application is sandboxed')
check(plists['Mac.entitlements']['com.apple.security.network.client'] and plists['Mac.entitlements']['com.apple.security.network.server'],'Mac has local client/listener sandbox capabilities')
for target in [v for v in objects.values() if v['isa']=='PBXNativeTarget']:
    configs=objects[target['buildConfigurationList']]['buildConfigurations']
    for config_id in configs:
        settings=objects[config_id]['buildSettings']
        standalone=target['name'].startswith('LocalChecklist-iPhone')
        check(settings['SUPPORTS_MACCATALYST']==('NO' if standalone else 'YES'),f'{target["name"]}: expected platform support')
        if standalone:
            check('STANDALONE_APP' in settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'], f'{target["name"]}: explicit standalone storage configuration')
        check(not any('CLOUDKIT' in key for key in settings),f'{target["name"]} has no cloud environment build setting')
for p in (p for folder in ['App','Shared','Sync','Widgets','Tests'] for p in (ROOT/folder).glob('*.swift')):
    check(not re.search(r'import\s+CloudKit\b|\bCKContainer\s*[.(]', p.read_text()),f'No active CloudKit route: {p.relative_to(ROOT)}')
for p in (ROOT/'Resources/Assets.xcassets').rglob('Contents.json'):
    asset=json.loads(p.read_text())
    for rendition in asset.get('images',[]):
        if 'filename' not in rendition:continue
        file=p.parent/rendition['filename']; data=file.read_bytes()
        check(data[:8]==b'\x89PNG\r\n\x1a\n',f'Icon is PNG: {file.name}')
        width,height=struct.unpack('>II',data[16:24])
        expected_size=int(rendition['size'].split('x')[0])*int(rendition.get('scale','1x')[:-1])
        check(width==height==expected_size,f'Icon rendition dimensions match: {file.name}')
icons=json.loads((ROOT/'Resources/Assets.xcassets/AppIcon.appiconset/Contents.json').read_text())['images']
check(any(x.get('idiom')=='mac' for x in icons),'Native Mac icon renditions exist')
for p in (ROOT/'App').glob('*.swift'):
    text=p.read_text()
    check(not re.search(r'\b(URLSession|CKContainer)\s*[.(]|import\s+(CloudKit|Firebase|Alamofire)\b',text),f'No direct HTTP/cloud/analytics client in UI: {p.name}')
quick=(ROOT/'App/QuickCapture.swift').read_text()
check('requiresOnDeviceRecognition = true' in quick,'Speech recognition forces on-device mode')
check('supportsOnDeviceRecognition' in quick,'Speech checks device support')
check('request.imageCropAndScaleOption' not in quick,'OCR has no unrelated Vision model preprocessing')
check('sourceText' in (ROOT/'App/LocalChecklistApp.swift').read_text(),'Quick capture stores original source text')
# Verify example schema and identity consistency independently of Swift.
example=json.loads((ROOT/'Examples/示例备份.json').read_text());payload=example['payload']
check(example['format']=='LocalChecklistBackup' and example['version']==1,'Example uses version 1 backup envelope')
ids=[x['id'] for kind in ['tasks','notes','anniversaries','lists'] for x in payload[kind]]
check(len(ids)==len(set(ids)),'Example IDs are unique across types')
list_ids={x['id'] for x in payload['lists']}
for task in payload['tasks']:
    check(task.get('listID') is None or task['listID'] in list_ids,'Example task references a valid list')
    check(task['isCompleted']==(task.get('completedAt') is not None),'Example completion metadata is consistent')
    for key in ['startDay','endDay']:
        if task.get(key):dt.date.fromisoformat(task[key])
for item in payload['anniversaries']:dt.date.fromisoformat(item['day'])
# Independent exhaustive Gregorian grid model (does not execute the Swift code).
for year in range(2000,2400):
    for month in range(1,13):
        first=dt.date(year,month,1); count=calendar.monthrange(year,month)[1]
        weekday=(first.weekday()+1)%7+1
        for first_weekday in range(1,8):
            offset=(weekday-first_weekday+7)%7
            total=((offset+count+6)//7)*7
            assert total in (28,35,42) and total-offset>=count
check(True,'Independent 400-year Gregorian grid arithmetic model passes')
print(f'PASS: {len(passed)} structural checks')
print(f'Swift sources: {sum(1 for folder in ["App","Shared","Sync","Widgets","Tests"] for _ in (ROOT/folder).glob("*.swift"))}')
print(f'XCTest cases authored: {sum(len(re.findall(r"func test",p.read_text())) for p in (ROOT/"Tests").glob("*.swift"))}')
print('NOT RUN: Swift typecheck/build, XCTest, Simulator, device, widgets, permissions, visual QA')
