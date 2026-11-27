import 'dart:convert';

bool _safe(dynamic x, [int max = 256]) =>
    x is String &&
    x.isNotEmpty &&
    x.length <= max &&
    !RegExp(
      r'[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2066-\u2069\u061c\ufeff]',
    ).hasMatch(x);
bool _count(dynamic x) => x is int && x >= 0;

/// The canonical action is the only source of lasting scope and future audience.
Map<String, dynamic> validateRuleAction(
  Map<String, dynamic> b,
  Map<String, dynamic> target, {
  required int now,
  String? ownerId,
  String? deviceId,
  int? generation,
}) {
  Never bad() => throw const FormatException('Invalid signed rule action');
  final action = b['action'];
  if (action is! String || utf8.encode(action).length > 3072) bad();
  final a = jsonDecode(action);
  if (a is! List ||
      !((a.length == 16 && a[1] == 5) || (a.length == 19 && a[1] == 6))) {
    bad();
  }
  if (a[0] != 'otpanda-rule' ||
      !_safe(a[2]) ||
      a[2] != b['intentId'] ||
      !_safe(a[3]) ||
      !_safe(a[4]) ||
      !_count(a[5]) ||
      !_count(a[9]) ||
      a[10] is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(a[10]) ||
      !_count(a[12]) ||
      !_count(a[13]) ||
      a[14] is! bool ||
      a[14] != (a[12] == 0 && a[13] == 0) ||
      b['proofRequired'] is! bool ||
      a[14] == b['proofRequired']) {
    bad();
  }
  if ((ownerId != null && ownerId != a[3]) ||
      (deviceId != null && deviceId != a[4]) ||
      (generation != null && generation != a[5])) {
    bad();
  }
  final op = a[6];
  if (!['review', 'edit', 'resume'].contains(op) ||
      op != target['operation'] ||
      a[7] != target[op == 'review' ? 'contextId' : 'ruleId'] ||
      a[8] != target['entryId'] ||
      !_safe(a[7]) ||
      !_safe(a[8])) {
    bad();
  }
  final exp = b['expiresAt'];
  if (exp is! int ||
      exp <= now ||
      exp > now + 120000 ||
      (op == 'review' ? a[11] is! int || a[11] < exp : a[11] != null)) {
    bad();
  }
  if (a[15] is! String) bad();
  final d = jsonDecode(a[15]);
  if (d is! List) bad();
  dynamic senderKind,
      sender,
      sourceId,
      serviceId,
      phrase,
      basis,
      overlaps,
      addressScope,
      before,
      phraseBefore;
  if (op == 'edit') {
    if (d.length != 10 ||
        d[0] != 'edit' ||
        !['template', 'phrase'].contains(d[5]) ||
        !['template', 'phrase'].contains(d[7]) ||
        (d[5] == 'template' ? d[6] != null : !_safe(d[6], 120)) ||
        (d[7] == 'template' ? d[8] != null : !_safe(d[8], 120))) {
      bad();
    }
    senderKind = d[1];
    sender = d[2];
    sourceId = d[3];
    serviceId = d[4];
    before = d[5];
    phraseBefore = d[6];
    basis = d[7];
    phrase = d[8];
    overlaps = d[9];
    if (target['phrase'] != phrase) bad();
  } else {
    if (d.length != 9 ||
        d[0] != (op == 'review' ? 'save' : 'resume') ||
        (d[3] != null && !_safe(d[3]))) {
      bad();
    }
    senderKind = d[1];
    sender = d[2];
    sourceId = d[4];
    serviceId = d[5];
    overlaps = d[8];
    addressScope = d[3] == null
        ? 'any-address-on-connector'
        : 'receiving-address';
    if (op == 'review') {
      phrase = d[6];
      if (d[7] is! bool ||
          (d[7] == true ? phrase != null : !_safe(phrase, 120))) {
        bad();
      }
      basis = d[7] == true ? 'template' : 'phrase';
      if (target['phrase'] != phrase) bad();
    } else {
      basis = d[6];
      phrase = d[7];
      if (!['template', 'phrase'].contains(basis) ||
          (basis == 'template' ? phrase != null : !_safe(phrase, 120))) {
        bad();
      }
    }
  }
  if (!['email_address', 'sms_number'].contains(senderKind) ||
      !_safe(sender) ||
      !_safe(sourceId) ||
      !_safe(serviceId) ||
      !_count(overlaps)) {
    bad();
  }
  final derived = <String, dynamic>{
    'operation': op == 'review'
        ? 'rule-from-review'
        : op == 'edit'
        ? 'rule-edit'
        : 'rule-resume',
    'entryId': a[8],
    'sender': sender,
    'senderKind': senderKind,
    'sourceId': sourceId,
    'serviceId': serviceId,
    'basis': basis,
    'phrase': phrase,
    'futureRecipients': a[12],
    'futureAutomations': a[13],
    'otherAccountRules': overlaps,
    'irreversible': false,
    if (op == 'edit') ...{
      'basisBefore': before,
      'phraseBefore': phraseBefore,
      'mayMatchOtherTemplates': true,
    } else ...{
      'addressScope': addressScope,
      if (op == 'review') 'previewRemoved': true else 'resumesPausedRule': true,
    },
  };
  final s = b['summary'];
  if (s is! Map<String, dynamic> ||
      derived.entries.any((e) => e.key != 'sourceId' && s[e.key] != e.value) ||
      !_safe(s['label'], 64) ||
      (s['accountName'] != null &&
          s['accountName'] != '' &&
          !_safe(s['accountName'], 128))) {
    bad();
  }
  if (a[1] == 6 &&
      (a[16] != s['label'] ||
          a[17] != (s['accountName'] ?? '') ||
          a[18] != serviceId)) {
    bad();
  }
  return {
    ...derived,
    'label': s['label'],
    'accountName': s['accountName'],
    'proofRequired': b['proofRequired'],
  };
}

String _plural(int n, String one, String many) => '$n ${n == 1 ? one : many}';
String ruleDisclosure(Map<String, dynamic> s) =>
    '${s['operation'] == 'rule-resume'
        ? 'Resume'
        : s['operation'] == 'rule-edit'
        ? 'Change'
        : 'Save'} the rule for ${s['sender']} on this connector. Match: ${s['basis'] == 'template' ? 'saved message template' : 'phrase "${s['phrase']}"'}. Future codes go to ${s['label']}, shared with ${_plural(s['futureRecipients'], 'recipient', 'recipients')} and ${_plural(s['futureAutomations'], 'automation grant', 'automation grants')}. ${_plural(s['otherAccountRules'], 'other account has', 'other accounts have')} potentially overlapping rules. A tie stays unassigned.${s['operation'] == 'rule-edit' ? ' Changing the phrase may match other message templates.' : ''}${s['previewRemoved'] == true ? ' This removes the review preview, not code history.' : ''}';
