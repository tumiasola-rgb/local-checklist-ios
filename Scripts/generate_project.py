#!/usr/bin/env python3
"""Maintainer utility only. The delivered .xcodeproj is ready to open in Xcode."""
from pathlib import Path
import hashlib, plistlib, json
ROOT = Path(__file__).resolve().parent.parent
objects = {}
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def add(identity, isa, **values):
    key = uid(identity); objects[key] = dict(isa=isa, **values); return key
def ref(path, filetype):
    return add('file:'+path, 'PBXFileReference', lastKnownFileType=filetype, path=path, sourceTree='<group>')
app_files = sorted(str(p.relative_to(ROOT)) for p in (ROOT/'App').glob('*.swift'))
shared = sorted(str(p.relative_to(ROOT)) for p in (ROOT/'Shared').glob('*.swift'))
widget_shared = shared
sync_folder = sorted(str(p.relative_to(ROOT)) for p in (ROOT/'Sync').glob('*.swift'))
app_files += sync_folder
widgets = sorted(str(p.relative_to(ROOT)) for p in (ROOT/'Widgets').glob('*.swift'))
tests = sorted(str(p.relative_to(ROOT)) for p in (ROOT/'Tests').glob('*.swift'))
refs = {p: ref(p, 'sourcecode.swift') for p in app_files+shared+widgets+tests}
asset = ref('Resources/Assets.xcassets', 'folder.assetcatalog')
privacy = ref('Resources/PrivacyInfo.xcprivacy', 'text.xml')
config = ref('Config/Signing.xcconfig','text.xcconfig')
others = [ref(p,'text.plist.xml') for p in ['Config/App-Info.plist','Config/Widget-Info.plist','Config/App.entitlements','Config/Widget.entitlements','Config/Mac.entitlements','Config/MacWidget.entitlements']]
app_product = add('app_product','PBXFileReference',explicitFileType='wrapper.application',includeInIndex='0',path='LocalChecklist.app',sourceTree='BUILT_PRODUCTS_DIR')
widget_product = add('widget_product','PBXFileReference',explicitFileType='wrapper.app-extension',includeInIndex='0',path='LocalChecklistWidgets.appex',sourceTree='BUILT_PRODUCTS_DIR')
test_product = add('test_product','PBXFileReference',explicitFileType='wrapper.cfbundle',includeInIndex='0',path='LocalChecklistTests.xctest',sourceTree='BUILT_PRODUCTS_DIR')
product_group = add('products','PBXGroup',children=[app_product,widget_product,test_product],name='Products',sourceTree='<group>')
main_group = add('main_group','PBXGroup',children=list(refs.values())+[asset,privacy,config]+others+[product_group],sourceTree='<group>')
def source_phase(name, files):
    buildfiles = [add(name+':'+p,'PBXBuildFile',fileRef=refs[p]) for p in files]
    return add(name+':sources','PBXSourcesBuildPhase',buildActionMask='2147483647',files=buildfiles,runOnlyForDeploymentPostprocessing='0')
def resource_phase(name, resources):
    files=[add(name+':res:'+r,'PBXBuildFile',fileRef=r) for r in resources]
    return add(name+':resources','PBXResourcesBuildPhase',buildActionMask='2147483647',files=files,runOnlyForDeploymentPostprocessing='0')
def frameworks(name): return add(name+':frameworks','PBXFrameworksBuildPhase',buildActionMask='2147483647',files=[],runOnlyForDeploymentPostprocessing='0')
def configs(name, settings, base=True):
    entries=[]
    for mode in ['Debug','Release']:
        st=dict(settings)
        st.update(SWIFT_OPTIMIZATION_LEVEL='-Onone' if mode=='Debug' else '-O', DEBUG_INFORMATION_FORMAT='dwarf' if mode=='Debug' else 'dwarf-with-dsym')
        if mode=='Debug': st.update(ENABLE_TESTABILITY='YES', SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG $(inherited)')
        if name=='widget': st['SWIFT_ACTIVE_COMPILATION_CONDITIONS']=('DEBUG ' if mode=='Debug' else '')+'$(inherited) WIDGET_EXTENSION'
        kwargs=dict(buildSettings=st,name=mode)
        if base: kwargs['baseConfigurationReference']=config
        entries.append(add(name+':'+mode,'XCBuildConfiguration',**kwargs))
    return add(name+':configs','XCConfigurationList',buildConfigurations=entries,defaultConfigurationIsVisible='0',defaultConfigurationName='Release')
common = dict(SDKROOT='iphoneos',SUPPORTED_PLATFORMS='iphoneos iphonesimulator macosx',SUPPORTS_MACCATALYST='YES',DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER='NO',SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD='NO',MACOSX_DEPLOYMENT_TARGET='14.0',TARGETED_DEVICE_FAMILY='1,2',CLANG_ENABLE_MODULES='YES',SWIFT_VERSION='5.0',IPHONEOS_DEPLOYMENT_TARGET='17.0',CODE_SIGN_STYLE='Automatic',GENERATE_INFOPLIST_FILE='NO',LD_RUNPATH_SEARCH_PATHS='$(inherited) @executable_path/Frameworks',SWIFT_STRICT_CONCURRENCY='targeted')
app_settings=dict(common,PRODUCT_NAME='LocalChecklist',PRODUCT_BUNDLE_IDENTIFIER='$(BASE_BUNDLE_IDENTIFIER)',INFOPLIST_FILE='Config/App-Info.plist',CODE_SIGN_ENTITLEMENTS='Config/App.entitlements',ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon',ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME='AccentColor',CURRENT_PROJECT_VERSION='2',MARKETING_VERSION='1.1',ENABLE_PREVIEWS='YES')
app_settings['CODE_SIGN_ENTITLEMENTS[sdk=macosx*]']='Config/Mac.entitlements'
app_settings['TARGETED_DEVICE_FAMILY[sdk=macosx*]']='6'
widget_settings=dict(common,PRODUCT_NAME='LocalChecklistWidgets',PRODUCT_BUNDLE_IDENTIFIER='$(BASE_BUNDLE_IDENTIFIER).widgets',INFOPLIST_FILE='Config/Widget-Info.plist',CODE_SIGN_ENTITLEMENTS='Config/Widget.entitlements',APPLICATION_EXTENSION_API_ONLY='YES',SKIP_INSTALL='YES',CURRENT_PROJECT_VERSION='2',MARKETING_VERSION='1.1',LD_RUNPATH_SEARCH_PATHS='$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks')
widget_settings['CODE_SIGN_ENTITLEMENTS[sdk=macosx*]']='Config/MacWidget.entitlements'
widget_settings['TARGETED_DEVICE_FAMILY[sdk=macosx*]']='6'
test_settings=dict(common,PRODUCT_NAME='LocalChecklistTests',PRODUCT_BUNDLE_IDENTIFIER='$(BASE_BUNDLE_IDENTIFIER).tests',GENERATE_INFOPLIST_FILE='YES',TEST_HOST='$(BUILT_PRODUCTS_DIR)/LocalChecklist.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/LocalChecklist',BUNDLE_LOADER='$(TEST_HOST)')
app_id=uid('target:app'); widget_id=uid('target:widget'); test_id=uid('target:test'); project_id=uid('project')
widget_proxy=add('widget_proxy','PBXContainerItemProxy',containerPortal=project_id,proxyType='1',remoteGlobalIDString=widget_id,remoteInfo='LocalChecklistWidgets')
widget_dep=add('widget_dep','PBXTargetDependency',target=widget_id,targetProxy=widget_proxy)
embed_file=add('embed_widget','PBXBuildFile',fileRef=widget_product,settings=dict(ATTRIBUTES=['RemoveHeadersOnCopy']))
embed=add('embed_phase','PBXCopyFilesBuildPhase',buildActionMask='2147483647',dstPath='',dstSubfolderSpec='13',files=[embed_file],name='Embed App Extensions',runOnlyForDeploymentPostprocessing='0')
app_proxy=add('app_proxy','PBXContainerItemProxy',containerPortal=project_id,proxyType='1',remoteGlobalIDString=app_id,remoteInfo='LocalChecklist')
app_dep=add('app_dep','PBXTargetDependency',target=app_id,targetProxy=app_proxy)
add('target:widget','PBXNativeTarget',buildConfigurationList=configs('widget',widget_settings),buildPhases=[source_phase('widget',widget_shared+widgets+['App/LocalNotificationScheduler.swift']),frameworks('widget'),resource_phase('widget',[privacy])],buildRules=[],dependencies=[],name='LocalChecklistWidgets',productName='LocalChecklistWidgets',productReference=widget_product,productType='com.apple.product-type.app-extension')
add('target:app','PBXNativeTarget',buildConfigurationList=configs('app',app_settings),buildPhases=[source_phase('app',shared+app_files),frameworks('app'),resource_phase('app',[asset,privacy]),embed],buildRules=[],dependencies=[widget_dep],name='LocalChecklist',productName='LocalChecklist',productReference=app_product,productType='com.apple.product-type.application')
add('target:test','PBXNativeTarget',buildConfigurationList=configs('tests',test_settings),buildPhases=[source_phase('tests',tests),frameworks('tests'),resource_phase('tests',[])],buildRules=[],dependencies=[app_dep],name='LocalChecklistTests',productName='LocalChecklistTests',productReference=test_product,productType='com.apple.product-type.bundle.unit-test')
add('project','PBXProject',attributes={'BuildIndependentTargetsInParallel':'YES','LastUpgradeCheck':'1600','TargetAttributes':{app_id:{'CreatedOnToolsVersion':'16.0','SystemCapabilities':{'com.apple.ApplicationGroups.iOS':{'enabled':'1'}}},widget_id:{'CreatedOnToolsVersion':'16.0','SystemCapabilities':{'com.apple.ApplicationGroups.iOS':{'enabled':'1'}}},test_id:{'CreatedOnToolsVersion':'16.0','TestTargetID':app_id}}},buildConfigurationList=configs('project',dict(ALWAYS_SEARCH_USER_PATHS='NO',CLANG_ENABLE_MODULES='YES',CLANG_ENABLE_OBJC_ARC='YES',GCC_C_LANGUAGE_STANDARD='gnu17',IPHONEOS_DEPLOYMENT_TARGET='17.0',SWIFT_VERSION='5.0',SDKROOT='iphoneos')),compatibilityVersion='Xcode 14.0',developmentRegion='zh-Hans',hasScannedForEncodings='0',knownRegions=['zh-Hans','en','Base'],mainGroup=main_group,productRefGroup=product_group,projectDirPath='',projectRoot='',targets=[app_id,widget_id,test_id])
# A separate iPhone product keeps the original App Group/widget product intact.
# It has its own bundle ID and uses Application Support, never a fallback store.
phone_id = uid('target:iphone'); phone_test_id = uid('target:iphone-tests')
phone_product = add('iphone_product', 'PBXFileReference', explicitFileType='wrapper.application', includeInIndex='0', path='LocalChecklist-iPhone.app', sourceTree='BUILT_PRODUCTS_DIR')
phone_test_product = add('iphone_test_product', 'PBXFileReference', explicitFileType='wrapper.cfbundle', includeInIndex='0', path='LocalChecklist-iPhoneTests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
objects[product_group]['children'] += [phone_product, phone_test_product]
objects[main_group]['children'].append(ref('Config/iPhone.entitlements', 'text.plist.xml'))
phone_settings = dict(app_settings, PRODUCT_NAME='LocalChecklist-iPhone', PRODUCT_MODULE_NAME='LocalChecklist', PRODUCT_BUNDLE_IDENTIFIER='com.yx469h39gt.localchecklist.iphone', DEVELOPMENT_TEAM='YX469H39GT', SUPPORTED_PLATFORMS='iphoneos iphonesimulator', SUPPORTS_MACCATALYST='NO', CODE_SIGN_ENTITLEMENTS='Config/iPhone.entitlements')
phone_settings.pop('CODE_SIGN_ENTITLEMENTS[sdk=macosx*]', None)
phone_settings.pop('TARGETED_DEVICE_FAMILY[sdk=macosx*]', None)
phone_configs = configs('iphone', phone_settings)
for config_id in objects[phone_configs]['buildConfigurations']:
    st = objects[config_id]['buildSettings']
    st['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = st.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '$(inherited)') + ' STANDALONE_APP'
add('target:iphone', 'PBXNativeTarget', buildConfigurationList=phone_configs, buildPhases=[source_phase('iphone', shared+app_files), frameworks('iphone'), resource_phase('iphone', [asset, privacy])], buildRules=[], dependencies=[], name='LocalChecklist-iPhone', productName='LocalChecklist-iPhone', productReference=phone_product, productType='com.apple.product-type.application')
phone_proxy = add('iphone_proxy', 'PBXContainerItemProxy', containerPortal=project_id, proxyType='1', remoteGlobalIDString=phone_id, remoteInfo='LocalChecklist-iPhone')
phone_dep = add('iphone_dep', 'PBXTargetDependency', target=phone_id, targetProxy=phone_proxy)
phone_test_settings = dict(test_settings, PRODUCT_NAME='LocalChecklist-iPhoneTests', PRODUCT_BUNDLE_IDENTIFIER='com.yx469h39gt.localchecklist.iphone.tests', DEVELOPMENT_TEAM='YX469H39GT', SUPPORTED_PLATFORMS='iphoneos iphonesimulator', SUPPORTS_MACCATALYST='NO', TEST_HOST='$(BUILT_PRODUCTS_DIR)/LocalChecklist-iPhone.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/LocalChecklist-iPhone')
phone_test_configs = configs('iphone-tests', phone_test_settings)
for config_id in objects[phone_test_configs]['buildConfigurations']:
    st = objects[config_id]['buildSettings']
    st['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = st.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '$(inherited)') + ' STANDALONE_APP'
add('target:iphone-tests', 'PBXNativeTarget', buildConfigurationList=phone_test_configs, buildPhases=[source_phase('iphone-tests', tests), frameworks('iphone-tests'), resource_phase('iphone-tests', [])], buildRules=[], dependencies=[phone_dep], name='LocalChecklist-iPhoneTests', productName='LocalChecklist-iPhoneTests', productReference=phone_test_product, productType='com.apple.product-type.bundle.unit-test')
objects[project_id]['targets'] += [phone_id, phone_test_id]
objects[project_id]['attributes']['TargetAttributes'][phone_id] = {'CreatedOnToolsVersion':'16.0'}
objects[project_id]['attributes']['TargetAttributes'][phone_test_id] = {'CreatedOnToolsVersion':'16.0', 'TestTargetID':phone_id}

def render(value, level=0):
    indent='\t'*level
    if isinstance(value,dict): return '{\n'+''.join('\t'*(level+1)+json.dumps(str(k),ensure_ascii=False)+' = '+render(v,level+1)+';\n' for k,v in value.items())+indent+'}'
    if isinstance(value,list): return '(\n'+''.join('\t'*(level+1)+render(v,level+1)+',\n' for v in value)+indent+')'
    return json.dumps(str(value),ensure_ascii=False)
project=ROOT/'LocalChecklist.xcodeproj'; project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n'+render(dict(archiveVersion='1',classes={},objectVersion='56',objects=objects,rootObject=project_id))+'\n')
workspace=project/'project.xcworkspace';workspace.mkdir(exist_ok=True)
(workspace/'contents.xcworkspacedata').write_text('<?xml version="1.0" encoding="UTF-8"?><Workspace version="1.0"><FileRef location="self:"></FileRef></Workspace>\n')
schemes=project/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
def bref(id,name,product):return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{id}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:LocalChecklist.xcodeproj"/>'
(schemes/'LocalChecklist.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{bref(app_id,'LocalChecklist','LocalChecklist.app')}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{bref(test_id,'LocalChecklistTests','LocalChecklistTests.xctest')}</TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{bref(app_id,'LocalChecklist','LocalChecklist.app')}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{bref(app_id,'LocalChecklist','LocalChecklist.app')}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
(ROOT/'Scripts/project_manifest.json').write_text(json.dumps({'objects':objects,'rootObject':project_id},ensure_ascii=False,indent=2))
(schemes/'LocalChecklist-Mac.xcscheme').write_text((schemes/'LocalChecklist.xcscheme').read_text())
phone_scheme = (schemes/'LocalChecklist.xcscheme').read_text()
phone_scheme = phone_scheme.replace(bref(app_id,'LocalChecklist','LocalChecklist.app'), bref(phone_id,'LocalChecklist-iPhone','LocalChecklist-iPhone.app'))
phone_scheme = phone_scheme.replace(bref(test_id,'LocalChecklistTests','LocalChecklistTests.xctest'), bref(phone_test_id,'LocalChecklist-iPhoneTests','LocalChecklist-iPhoneTests.xctest'))
(schemes/'LocalChecklist-iPhone.xcscheme').write_text(phone_scheme)
print(f'Generated Xcode project: {len(app_files)} app / {len(shared)} shared / {len(widgets)} widget / {len(tests)} test source files')
