//> using scala "3.7.4"
//> using dep "dev.zio::zio:2.1.26"

import zio._

import scala.collection.mutable.ArrayBuffer
import scala.util.matching.Regex
import java.lang.{System => JSystem}

object RuntimeOverheadZio:
  final case class Opts(
      quick: Boolean,
      filterRaw: Option[String],
      filter: Option[Regex],
      samples: Int,
      warmupMs: Long
  )

  final case class Workload(name: String, run: () => Unit, samples: Option[Int] = None)

  private var intSink: Int = 0
  private val BindN = 100_000
  private val FailN = 100_000
  private val One = 1

  def main(args: Array[String]): Unit =
    val opts = parseArgs(args.toList)
    (directAndMiniWorkloads ++ zioWorkloads ++ realuseWorkloads).foreach(runWorkload(opts, _))
    if intSink == Int.MinValue then JSystem.err.println("sink hit")

  private def parseArgs(args: List[String]): Opts =
    var quick = false
    var filterRaw: Option[String] = None
    var filter: Option[Regex] = None
    var samples: Option[Int] = None
    var warmupMs: Option[Long] = None
    var rest = args
    while rest.nonEmpty do
      rest match
        case Nil => ()
        case "--quick" :: tail =>
          quick = true
          rest = tail
        case "--filter" :: value :: tail =>
          filterRaw = Some(value)
          filter = Some(value.r)
          rest = tail
        case "--samples" :: value :: tail =>
          samples = Some(value.toInt)
          rest = tail
        case "--warmup-ms" :: value :: tail =>
          warmupMs = Some(value.toLong)
          rest = tail
        case arg :: _ =>
          throw IllegalArgumentException(s"unknown bench argument: $arg")
    Opts(
      quick,
      filterRaw,
      filter,
      samples.getOrElse(if quick then 1 else 10),
      warmupMs.getOrElse(if quick then 100L else 2000L)
    )

  private def shouldRun(opts: Opts, name: String): Boolean =
    opts.filter match
      case None => true
      case Some(re) if re.findFirstIn(name).nonEmpty => true
      case _ =>
        opts.filterRaw.exists(_.split("\\|").exists(part => part.nonEmpty && name.contains(part)))

  private def jsonString(s: String): String =
    val b = StringBuilder()
    b.append('"')
    s.foreach {
      case '"'  => b.append("\\\"")
      case '\\' => b.append("\\\\")
      case '\b' => b.append("\\b")
      case '\f' => b.append("\\f")
      case '\n' => b.append("\\n")
      case '\r' => b.append("\\r")
      case '\t' => b.append("\\t")
      case c if c < ' ' => b.append("\\u").append(f"${c.toInt}%04x")
      case c => b.append(c)
    }
    b.append('"')
    b.toString

  private def fmt(n: Double): String =
    if n.isNaN || n.isInfinite then "0" else f"$n%.6f"

  private def mean(xs: Vector[Double]): Double =
    if xs.isEmpty then 0.0 else xs.sum / xs.length.toDouble

  private def stddev(xs: Vector[Double]): Double =
    if xs.length < 2 then 0.0
    else
      val m = mean(xs)
      math.sqrt(xs.map(x => (x - m) * (x - m)).sum / (xs.length - 1).toDouble)

  private def emit(name: String, metric: String, unit: String, samples: Vector[Double]): Unit =
    val sampleJson = samples.map(fmt).mkString(",")
    val b = StringBuilder()
    b.append("{\"name\":").append(jsonString(name))
    b.append(",\"metric\":").append(jsonString(metric))
    b.append(",\"unit\":").append(jsonString(unit))
    b.append(",\"samples\":[").append(sampleJson).append("]")
    b.append(",\"mean\":").append(fmt(mean(samples)))
    b.append(",\"stddev\":").append(fmt(stddev(samples)))
    b.append(",\"min\":").append(fmt(samples.min))
    b.append(",\"max\":").append(fmt(samples.max))
    b.append("}")
    println(b.toString)

  private def gc(): Unit =
    JSystem.gc()

  private def measureOnce(run: () => Unit): Double =
    gc()
    val start = JSystem.nanoTime()
    run()
    (JSystem.nanoTime() - start).toDouble

  private def warmup(run: () => Unit, warmupMs: Long): Unit =
    if warmupMs <= 0 then run()
    else
      val deadline = JSystem.nanoTime() + (warmupMs * 1_000_000L)
      run()
      while JSystem.nanoTime() < deadline do
        run()

  private def runWorkload(opts: Opts, workload: Workload): Unit =
    if shouldRun(opts, workload.name) then
      warmup(workload.run, opts.warmupMs)
      val count = workload.samples.getOrElse(opts.samples)
      val samples = Vector.fill(count)(measureOnce(workload.run))
      emit(workload.name, "wall_ns", "ns", samples)

  private def directLoop(n: Int): Unit =
    var acc = 0
    var i = 0
    while i < n do
      acc = acc + One
      i += 1
    intSink = acc

  private def directClosureBind(n: Int): Unit =
    def bind[A, B](x: A)(f: A => B): B = f(x)
    def pure[A](x: A): A = x
    var acc = 0
    var i = 0
    while i < n do
      acc = bind(acc)(x => pure(x + One))
      i += 1
    intSink = acc

  private enum Mini[+E, +A]:
    case Pure[A](value: A) extends Mini[Nothing, A]
    case Fail[E](err: E) extends Mini[E, Nothing]
    case Bind[E, A, B](left: Mini[E, A], k: A => Mini[E, B]) extends Mini[E, B]
    case Catch[E, A](body: Mini[E, A], handler: E => Mini[E, A]) extends Mini[E, A]

  private enum Frame:
    case BindK(k: Any => Mini[Any, Any])
    case CatchH(handler: Any => Mini[Any, Any])

  private def runMini[A](start: Mini[Any, A]): Either[Any, A] =
    import Frame._
    import Mini._
    val stack = ArrayBuffer.empty[Frame]
    var cur: Mini[Any, Any] = start.asInstanceOf[Mini[Any, Any]]
    while true do
      cur match
        case Pure(value) =>
          var value0: Any = value
          var done = false
          while !done do
            if stack.isEmpty then return Right(value0.asInstanceOf[A])
            stack.remove(stack.length - 1) match
              case BindK(k) =>
                cur = k(value0)
                done = true
              case CatchH(_) => ()
        case Fail(err) =>
          var err0: Any = err
          var done = false
          while !done do
            if stack.isEmpty then return Left(err0)
            stack.remove(stack.length - 1) match
              case CatchH(handler) =>
                cur = handler(err0)
                done = true
              case BindK(_) => ()
        case Bind(left, k) =>
          stack.append(BindK(k.asInstanceOf[Any => Mini[Any, Any]]))
          cur = left.asInstanceOf[Mini[Any, Any]]
        case Catch(body, handler) =>
          stack.append(CatchH(handler.asInstanceOf[Any => Mini[Any, Any]]))
          cur = body.asInstanceOf[Mini[Any, Any]]
    Right(throw IllegalStateException("unreachable"))

  private def miniBindChain(n: Int, acc: Mini[Nothing, Int]): Mini[Nothing, Int] =
    import Mini._
    var cur = acc
    var i = 0
    while i < n do
      cur = Bind(cur, (x: Int) => Pure(x + 1))
      i += 1
    cur

  private def miniFailCatchLoop(n: Int): Mini[String, Int] =
    import Mini._
    def go(i: Int, acc: Int): Mini[String, Int] =
      if i == 0 then Pure(acc) else Catch(Fail("Boom"), _ => go(i - 1, acc + 1))
    go(n, 0)

  private def runMiniInt(program: Mini[Any, Int]): Unit =
    runMini(program) match
      case Right(value) => intSink = value
      case Left(_) => throw RuntimeException("unexpected mini failure")

  private def runZioInt(program: UIO[Int]): Unit =
    intSink = Unsafe.unsafe { implicit unsafe =>
      Runtime.default.unsafe.run(program).getOrThrowFiberFailure()
    }

  private def runZioIgnore[A](program: UIO[A]): Unit =
    Unsafe.unsafe { implicit unsafe =>
      Runtime.default.unsafe.run(program).getOrThrowFiberFailure()
    }
    intSink = 0

  private def zioBindChain(n: Int, acc: UIO[Int]): UIO[Int] =
    var cur = acc
    var i = 0
    while i < n do
      cur = cur.flatMap(x => ZIO.succeed(x + 1))
      i += 1
    cur

  private def zioFailCatchLoop(n: Int): UIO[Int] =
    def go(i: Int, acc: Int): UIO[Int] =
      if i == 0 then ZIO.succeed(acc)
      else ZIO.fail("Boom").catchAll(_ => go(i - 1, acc + 1))
    go(n, 0)

  private def zioRunSyncPureLoop(n: Int): Unit =
    val program = ZIO.succeed(0)
    var i = 0
    var last = 0
    while i < n do
      last = Unsafe.unsafe { implicit unsafe =>
        Runtime.default.unsafe.run(program).getOrThrowFiberFailure()
      }
      i += 1
    intSink = last

  private def work50(): UIO[Int] =
    zioBindChain(50, ZIO.succeed(0))

  private def realuseFanoutPar64x50(): UIO[Int] =
    ZIO.foreachPar(0 until 64)(_ => work50().as(1)).map(_.sum)

  private def realuseFanoutBounded512x50K8(): UIO[Int] =
    ZIO.foreachPar(0 until 512)(_ => work50().as(1)).withParallelism(8).map(_.sum)

  private def realuseRetryFlaky(): UIO[Int] =
    def oneRun(ref: Ref[Int]): IO[String, Int] =
      val attempt = ref.updateAndGet(_ + 1)
      attempt.flatMap(n => if n < 5 then ZIO.fail("Boom") else ZIO.succeed(n))
        .retry(Schedule.recurs(10))
    def loop(ref: Ref[Int], remaining: Int, acc: Int): UIO[Int] =
      if remaining == 0 then ZIO.succeed(acc)
      else
        ref.set(0) *>
          oneRun(ref)
            .catchAll(err => ZIO.dieMessage(err))
            .flatMap(v => loop(ref, remaining - 1, acc + v))
    Ref.make(0).flatMap(ref => loop(ref, 100, 0))

  private def realusePipelineBindCatch1k(): UIO[Int] =
    val prefix = zioBindChain(500, ZIO.succeed(0))
    val recovered = prefix.flatMap(acc => ZIO.fail("Boom").catchAll(_ => ZIO.succeed(acc)))
    recovered.flatMap(base => zioBindChain(500, ZIO.succeed(base)))

  private def realuseScopeAcquireRelease64(): UIO[Int] =
    def build(ref: Ref[Int], depth: Int): ZIO[Scope, Nothing, Int] =
      if depth == 0 then ZIO.succeed(0)
      else
        ZIO.acquireRelease(ref.updateAndGet(_ + 1))(_ => ref.update(_ - 1))
          .flatMap(v => build(ref, depth - 1).map(_ + v))
    Ref.make(0).flatMap(ref => ZIO.scoped(build(ref, 64)))

  private def w(name: String)(run: () => Unit): Workload =
    Workload(s"overhead.zio.$name", run)

  private def rw(name: String)(run: () => Unit): Workload =
    Workload(s"realuse.zio.$name", run)

  private def directAndMiniWorkloads: List[Workload] =
    val miniBind = miniBindChain(BindN, Mini.Pure(0))
    val miniFail = miniFailCatchLoop(FailN)
    List(
      w("direct.loop.100k")(() => directLoop(BindN)),
      w("direct.closure_bind.100k")(() => directClosureBind(BindN)),
      w("mini.bind.100k.prebuilt")(() => runMiniInt(miniBind.asInstanceOf[Mini[Any, Int]])),
      w("mini.bind.100k.build_run")(() => runMiniInt(miniBindChain(BindN, Mini.Pure(0)).asInstanceOf[Mini[Any, Int]])),
      w("mini.fail_catch.100k.prebuilt")(() => runMiniInt(miniFail.asInstanceOf[Mini[Any, Int]])),
      w("mini.fail_catch.100k.build_run")(() => runMiniInt(miniFailCatchLoop(FailN).asInstanceOf[Mini[Any, Int]]))
    )

  private def zioWorkloads: List[Workload] =
    val bind = zioBindChain(BindN, ZIO.succeed(0))
    val fail = zioFailCatchLoop(FailN)
    List(
      w("zio.runSync_pure.100k")(() => zioRunSyncPureLoop(BindN)),
      w("zio.bind.100k.prebuilt")(() => runZioInt(bind)),
      w("zio.bind.100k.build_run")(() => runZioInt(zioBindChain(BindN, ZIO.succeed(0)))),
      w("zio.fail_catch.100k.prebuilt")(() => runZioInt(fail)),
      w("zio.fail_catch.100k.build_run")(() => runZioInt(zioFailCatchLoop(FailN)))
    )

  private def realuseWorkloads: List[Workload] =
    List(
      rw("fanout.par.success.64x50")(() => runZioIgnore(realuseFanoutPar64x50())),
      rw("fanout.bounded.512x50.k=8")(() => runZioIgnore(realuseFanoutBounded512x50K8())),
      rw("retry.flaky.fail4_then_ok")(() => runZioIgnore(realuseRetryFlaky())),
      rw("pipeline.bind_catch.1k")(() => runZioIgnore(realusePipelineBindCatch1k())),
      rw("scope.acquire_release.64")(() => runZioIgnore(realuseScopeAcquireRelease64()))
    )
