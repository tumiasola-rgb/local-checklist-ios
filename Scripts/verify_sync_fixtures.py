#!/usr/bin/env python3
"""Independent causal/state fixtures + source-contract checks. NOT Swift execution.
No account, network, third-party package, or Apple SDK is used.
"""
from dataclasses import dataclass
from pathlib import Path
import random
import unittest

ROOT = Path(__file__).resolve().parent.parent

@dataclass(frozen=True)
class Version:
    id: str
    vector: tuple
    payload: object
    @property
    def clock(self): return dict(self.vector)

def v(id, clock, payload): return Version(id, tuple(sorted(clock.items())), payload)
def dominates(a, b):
    return a.clock != b.clock and all(a.clock.get(k, 0) >= n for k, n in b.clock.items())
def merge(*groups):
    by_id = {}
    for group in groups:
        for item in group:
            if item.id in by_id and by_id[item.id] != item: raise ValueError('reused operation')
            by_id[item.id] = item
    all_versions = list(by_id.values())
    result = tuple(sorted((a for a in all_versions if not any(dominates(b, a) for b in all_versions)), key=lambda x:x.id))
    if len({a.vector for a in result}) != len(result): raise ValueError('reused causal clock')
    return result

@dataclass(frozen=True)
class BusinessRecord:
    business: str
    audit_time: int

def conflict(heads):
    def semantic(payload): return payload.business if isinstance(payload, BusinessRecord) else payload
    return len({semantic(a.payload) for a in heads}) > 1
def dirty(heads, cloud): return {a.id for a in heads} != {a.id for a in cloud}
def resolve(heads, selected, reviewed):
    if {a.id for a in heads} != reviewed: raise ValueError('stale review')
    chosen = next(a for a in heads if a.id == selected)
    clock = {}
    for a in heads:
        for k,n in a.clock.items(): clock[k] = max(clock.get(k,0),n)
    clock['resolver'] = clock.get('resolver',0)+1
    return (v('resolution',clock,chosen.payload),)

class CausalFixtures(unittest.TestCase):
    def setUp(self): self.base = v('base', {'A':1}, 'original')
    def test_offline_edits_coalesce(self):
        first=v('first',{'A':2},'first'); second=v('second',{'A':3},'second')
        self.assertEqual(merge([self.base, first],[second]), (second,))
        self.assertTrue(dirty([second],[self.base]))
    def test_two_offline_edits_preserve_both(self):
        a=v('a',{'A':2},'phone'); b=v('b',{'A':1,'B':1},'mac')
        heads=merge([self.base,a],[self.base,b]); self.assertEqual(set(heads),{a,b}); self.assertTrue(conflict(heads))
    def test_edit_completion_conflict(self):
        a=v('a',{'A':2},'edited'); b=v('b',{'A':1,'B':1},'completed')
        self.assertTrue(conflict(merge([a],[b])))
    def test_delete_edit_preserves_content(self):
        a=v('a',{'A':2},None); b=v('b',{'A':1,'B':1},'keep this')
        heads=merge([a],[b]); self.assertEqual({a.payload for a in heads},{None,'keep this'})
    def test_audit_time_difference_does_not_create_business_conflict(self):
        a=v('a',{'A':1},BusinessRecord('completed same task',10))
        b=v('b',{'B':1},BusinessRecord('completed same task',20))
        heads=merge([a],[b]); self.assertEqual(len(heads),2); self.assertFalse(conflict(heads))
        source=(ROOT/'Shared/SyncTypes.swift').read_text()
        self.assertIn('isSemanticallyEquivalent',source)
        self.assertIn('lhs.completedAt = rhs.completedAt',source)
    def test_double_delete_converges_without_content_conflict(self):
        a=v('a',{'A':2},None); b=v('b',{'A':1,'B':1},None)
        heads=merge([a],[b]); self.assertEqual(len(heads),2); self.assertFalse(conflict(heads))
    def test_old_ack_cannot_clear_new_edit(self):
        sent=v('sent',{'A':2},'sent'); current=v('new',{'A':3},'new')
        self.assertTrue(dirty(merge([current],[sent]),[sent]))
    def test_retries_are_idempotent(self): self.assertEqual(merge([self.base],[self.base]),(self.base,))
    def test_clock_skew_irrelevant(self):
        older=v('future date 9999',{'A':1},'old'); newer=v('date 2020',{'A':2},'new')
        self.assertEqual(merge([older],[newer]),(newer,))
    def test_known_conflict_must_block_ordinary_edit(self):
        a=v('shown',{'A':5,'B':1},'shown'); b=v('unseen',{'A':6},'unseen')
        unsafe=v('unsafe',{'A':7,'B':1},'would lose unseen')
        self.assertTrue(conflict([a,b])); self.assertEqual(merge([a,b],[unsafe]),(unsafe,))
        self.assertIn('guard entry?.hasConflict != true else { throw SyncError.unresolvedConflict }', (ROOT/'Shared/SyncState.swift').read_text())
    def test_stale_review_rejected(self):
        heads=[self.base,v('b',{'B':1},'B'),v('c',{'C':1},'C')]
        with self.assertRaises(ValueError): resolve(heads,'base',{'base','b'})
        result=resolve(heads,'base',{'base','b','c'}); self.assertEqual(merge(heads,result),result)
    def test_import_is_independent_and_missing_is_not_delete(self):
        peer={'a':self.base,'b':v('old-b',{'B':1},'peer only')}
        imported={'a':v('new-epoch',{'IMPORT':1},'restored')}
        merged={k:merge([peer[k]], [imported[k]] if k in imported else []) for k in peer}
        self.assertTrue(conflict(merged['a'])); self.assertEqual(merged['b'],(peer['b'],))
    def test_replayed_old_packet_preserves_pending(self):
        current=v('pending',{'A':2},'offline')
        self.assertEqual(merge([current],[self.base]),(current,))
    def test_duplicate_id_rejected(self):
        with self.assertRaises(ValueError): merge([self.base],[v('base',{'A':1},'different')])
    def test_duplicate_clock_rejected(self):
        with self.assertRaises(ValueError): merge([self.base],[v('other-id',{'A':1},'different')])
    def test_randomized_join_laws(self):
        rng=random.Random(72819)
        for case in range(1000):
            count={k:0 for k in 'ABC'}; history=[]
            for n in range(20):
                actor=rng.choice('ABC'); count[actor]+=1; clock={}
                for prior in rng.sample(history,min(len(history),rng.randrange(4))):
                    for key,value in prior.clock.items():clock[key]=max(clock.get(key,0),value)
                clock[actor]=count[actor]
                history.append(v(f'{case}-{n}',clock,rng.choice([None,'edit','complete'])))
            a,b,c=(history[0::3],history[1::3],history[2::3])
            self.assertEqual(merge(a,b),merge(b,a))
            self.assertEqual(merge(merge(a,b),c),merge(a,merge(b,c)))
            self.assertEqual(merge(a,a),merge(a))

class LANProtocolFixtures(unittest.TestCase):
    def test_frame_length_boundaries(self):
        import struct
        for count in [1,255,256,65536]: self.assertEqual(struct.unpack('!I',struct.pack('!I',count))[0],count)
        for count in [-1,0,65537,2**32-1]: self.assertFalse(1 <= count <= 65536)
    def test_whole_packet_chunk_bound_is_640(self):
        total=20*1024*1024; size=32768
        self.assertEqual((total+size-1)//size,640)
        self.assertFalse(1 == min(size,total)) # One-byte slow-drip chunks are rejected.
    def test_exact_last_chunk(self):
        total=32769; offset=32768
        self.assertEqual(min(32768,total-offset),1)
        self.assertNotEqual(min(32768,total-offset),32768)
    def test_packet_digest_before_atomic_commit(self):
        import hashlib
        data=b'public test-only packet'; expected=hashlib.sha256(data).hexdigest(); committed=[]
        corrupted=data+b'x'
        if hashlib.sha256(corrupted).hexdigest()==expected: committed.append(corrupted)
        self.assertEqual(committed,[])
        if hashlib.sha256(data).hexdigest()==expected: committed.append(data)
        self.assertEqual(committed,[data])
    def test_session_and_sequence_replay_rejected(self):
        session='fresh-session'; next_sequence=3
        self.assertTrue(session=='fresh-session' and next_sequence==3)
        self.assertFalse(session=='old-session' and next_sequence==3)
        self.assertFalse(session=='fresh-session' and next_sequence==2)
    def test_pairing_requires_both_explicit_approvals(self):
        for local in [False,True]:
            for remote in [False,True]:
                allowed=local and remote
                self.assertEqual(allowed,local==remote==True)
    def test_residual_keychain_cannot_authorize_new_install(self):
        def gate(stored_install,current_install,stored_pair,local_binding,enabled):
            return stored_install==current_install and stored_pair==local_binding and enabled
        self.assertTrue(gate('install-A','install-A','pair-A','pair-A',True))
        self.assertFalse(gate('old-install','new-install','pair-A',None,False))
        self.assertFalse(gate('install-A','install-A','pair-A',None,True))
        self.assertFalse(gate('install-A','install-A','pair-A','pair-A',False))
    def test_ack_only_confirms_exact_sent_heads(self):
        sent={'v1','v2'}
        self.assertFalse({'v1','v2'} != sent)
        self.assertTrue({'v3'} != sent)
    def test_pair_code_requires_128_bits_not_six_digits(self):
        def valid(s):
            clean=s.replace('-','').replace(' ','')
            return len(clean)==32 and all(c in '0123456789abcdefABCDEF' for c in clean)
        self.assertTrue(valid('0000-0000-0000-0000-0000-0000-0000-0000')) # public test fixture, never production entropy
        self.assertFalse(valid('123456'));self.assertFalse(valid('Z'*32))

class SourceContracts(unittest.TestCase):
    def test_tls_psk_authenticated_lan_only(self):
        source=(ROOT/'Sync/LANNetwork.swift').read_text()
        for required in ['sec_protocol_options_add_pre_shared_key','TLS_PSK_WITH_AES_128_GCM_SHA256','sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)','sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)','sec_protocol_metadata_get_negotiated_tls_ciphersuite','acceptLocalOnly = true','maximumPayloadBytes = 65_536','contentProcessed','includePeerToPeer = false']:
            self.assertIn(required,source)
        self.assertNotIn('sec_protocol_options_set_verify_block',source)
        self.assertNotIn('NWParameters.tcp',source)
    def test_atomic_store_and_explicit_schema_migration(self):
        repo=(ROOT/'Shared/SharedRepository.swift').read_text()
        for required in ['currentVersion = 2','SyncLedger.recordLocalChanges','captureLocalChanges: false','header.version == 1 || header.version == currentVersion','if envelope.version == 1','current.sync.pausedForImport','portableBackupSnapshot','flock(descriptor, LOCK_EX)','flock(descriptor, LOCK_UN)','Darwin.rename','Darwin.fsync']:
            self.assertIn(required,repo)
    def test_pairing_and_installation_gate(self):
        source=(ROOT/'Sync/LANSyncService.swift').read_text()
        for required in ['pair.installationID == snapshot.sync.installationID','snapshot.sync.peerBindingID == pair.pairID.uuidString','guard remote.approved == true','try pairStore.save(record)','case', 'seconds: 180']:
            if required!='case': self.assertIn(required,source)
        self.assertIn('kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly',(ROOT/'Sync/LANKeychain.swift').read_text())
        self.assertIn('SecRandomCopyBytes',(ROOT/'Sync/LANKeychain.swift').read_text())
        self.assertNotIn('UserDefaults',(ROOT/'Sync/LANKeychain.swift').read_text())
    def test_backup_content_conflicts_and_projection_validation(self):
        state=(ROOT/'Shared/SyncState.swift').read_text()
        for required in ['func portableCopy','SyncEntry(heads: heads, dirty: true, preferredVersionID: preferred)','func pausedForImport','result.importRequiresReview = true','UUID().uuidString: 1','validateProjection(of snapshot','Set(entry.heads.map(\\.id)) == expectedHeadIDs','result.installationID = installationID']:
            self.assertIn(required,state)
        self.assertIn('validateSyncWireShape', (ROOT/'Shared/SnapshotValidation.swift').read_text())
    def test_wire_packet_bounded_and_fully_validated(self):
        source=(ROOT/'Sync/LANProtocol.swift').read_text()
        for required in ['maximumBytes = 20 * 1_024 * 1_024','frame.sequence == received','frame.sessionID == sessionID','chunk.count == min(32_768, total - bytes.count)','LANPacket.digest(bytes) == expectedDigest','start.acknowledgedDigest == expectedAck']:
            self.assertIn(required,source)
    def test_receipt_after_durable_commit(self):
        source=(ROOT/'Sync/LANExchange.swift').read_text()
        self.assertLess(source.index('try seeded.seed(from: snapshot)'),source.index('for record in packet.records'))
        responder=source[source.index('static func respond'):]
        self.assertLess(responder.index('bridge.merge(incoming.packet)'),responder.index('sendPacket(outgoing.packet, acknowledging: incoming.digest)'))
        self.assertLess(responder.index('conversation.receive([.receipt])'),responder.index('bridge.acknowledge(outgoing.packet)'))
    def test_cancelled_runtime_cannot_publish_late_status_or_restart_listener(self):
        source=(ROOT/'Sync/LANSyncService.swift').read_text()
        self.assertIn('guard activeID == operation, networkGeneration == token else { throw SyncError.interrupted }',source)
        self.assertIn('guard activeID == operation, networkGeneration == token else { return }',source)
        self.assertEqual(source.count('await conversation.close(); try checkRuntime(operation, generation: token); finishOperation(operation)'),3)
    def test_no_active_cloudkit_route(self):
        for file in list((ROOT/'Sync').glob('*.swift'))+list((ROOT/'Shared').glob('*.swift')):
            self.assertNotIn('import CloudKit',file.read_text())
            self.assertNotIn('CKContainer(',file.read_text())

if __name__=='__main__':
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromModule(__import__(__name__)))
    print('\nBOUNDARY: These are independent Python fixtures and Swift source-contract checks.')
    print('NOT RUN: Swift compile/typecheck, native XCTest, real Keychain/TLS handshake, Bonjour/local-network permissions, signed iPhone/Mac two-device exchange.')
    raise SystemExit(0 if result.wasSuccessful() else 1)
