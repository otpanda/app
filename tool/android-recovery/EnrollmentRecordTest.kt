package org.otpanda.recovery
fun main() {
    val public=byteArrayOf(1,2,3)
    val record=EnrollmentRecord("owner","key",EnrollmentRecord.hash(public))
    check(EnrollmentRecord.decode(record.encode())==record)
    check(enrolledState(null,null)=="not-enrolled")
    check(enrolledState(null,public)=="unconfirmed-local-key")
    check(enrolledState(record,null)=="enrolled-key-unavailable")
    check(enrolledState(record,byteArrayOf(3,2,1))=="enrolled-key-mismatch")
    check(enrolledState(record,public)=="enrolled-unverified-platform-policy")
    for(bad in listOf("",record.encode()+"extra",record.encode().replace("owner","own\ner"),record.encode().replace("key","key/other"),"x".repeat(401)))check(runCatching{EnrollmentRecord.decode(bad)}.isFailure)
    validateEnrollmentCandidate(null,null)
    validateEnrollmentCandidate(null,public)
    validateEnrollmentCandidate(record,public)
    check(runCatching{validateEnrollmentCandidate(record,null)}.isFailure)
    check(runCatching{validateEnrollmentCandidate(record,byteArrayOf(4))}.isFailure)
    println("PASS nonsecret metadata exact encoding, missing/replaced key fails closed; no hardware assurance inferred")
}
