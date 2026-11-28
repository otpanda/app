package app.otpanda.pickerfx
import android.os.Bundle
import android.util.Log
import app.otpanda.MainActivity
import app.otpanda.ImportJournalStore
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger

/** Synthetic disposable-package only. Exercises actual production AtomicFile store. */
class JournalFixtureActivity:MainActivity(){
 override fun onCreate(state:Bundle?){super.onCreate(state)
  Thread{try{runChecks(intent.getStringExtra("phase")?:"checks");Log.i("JOURNALFX","PASS complete")}catch(_:Throwable){Log.i("JOURNALFX","FAIL check")}}.start()
 }
 private fun record(n:Char,outcome:String="pending")="""{"v":2,"ownerId":"owner","deviceId":"device","nonce":"v2:${n.toString().repeat(32)}","admissionId":"${n.toString().repeat(32)}","count":1,"outcome":"$outcome"}"""
 private var checkNumber=0
 private fun check(value:Boolean){checkNumber++;if(!value){Log.i("JOURNALFX","FAIL assertion_$checkNumber");throw IllegalStateException()}}
 private fun runChecks(phase:String){
 val file=File(noBackupFilesDir,"otpanda-import-attempt-v2");val s=ImportJournalStore(this)
 if(phase=="prepare"){check(s.read()==null);check(s.claim(record('P')));Log.i("JOURNALFX","PASS prepared_pending");return}
 if(phase=="resume"){check(s.read()==record('P'));check(!s.claim(record('N')));check(s.replace(record('P'),record('P',"saved")));check(!s.clear(record('N',"saved")));check(s.clear(record('P',"saved")));Log.i("JOURNALFX","PASS process_restart_pending");return}
 check(s.read()==null)
 val start=CountDownLatch(1);val done=CountDownLatch(16);val winners=AtomicInteger()
 repeat(16){i->Thread{try{start.await();if(ImportJournalStore(this).claim(record(('A'.code+i).toChar())))winners.incrementAndGet()}finally{done.countDown()}}.start()}
 start.countDown();check(done.await(20,java.util.concurrent.TimeUnit.SECONDS));check(winners.get()==1)
 val pending=s.read()!!;val terminal=pending.replace("pending","saved");check(s.replace(pending,terminal));check(!s.replace(pending,pending.replace("pending","fenced")));check(s.clear(terminal));Log.i("JOURNALFX","PASS cross_instance_atomic_cas")
 // Android AtomicFile's documented legacy backup recovery path, real platform implementation.
 check(s.claim(record('R')));check(file.renameTo(File(file.path+".bak")));file.writeText("partial")
 check(ImportJournalStore(this).read()==record('R'));check(s.replace(record('R'),record('R',"fenced")));check(s.clear(record('R',"fenced")));Log.i("JOURNALFX","PASS atomicfile_backup_recovery")
 file.writeText("invalid");var rejected=false;try{s.read()}catch(_:Exception){rejected=true};check(rejected);rejected=false;try{s.claim(record('F'))}catch(_:Exception){rejected=true};check(rejected);check(file.readText()=="invalid");file.delete();Log.i("JOURNALFX","PASS corrupt_fail_closed")
 }
}
