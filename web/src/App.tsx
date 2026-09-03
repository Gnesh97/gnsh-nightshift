import { useCallback, useEffect, useState } from "react"
import { ArrowRightIcon, Clock3Icon, MapPinIcon, ShieldCheckIcon, StarIcon, XIcon } from "lucide-react"

import { Avatar, AvatarFallback } from "@/components/ui/avatar"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardAction, CardContent, CardFooter, CardHeader, CardTitle } from "@/components/ui/card"
import { Separator } from "@/components/ui/separator"
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet"
import { Skeleton } from "@/components/ui/skeleton"
import { Spinner } from "@/components/ui/spinner"
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group"
import { nuiRequest } from "@/lib/nui"
import type { BookingDraft, ClientBooking, ClientBookingPage, PriceQuote, WorkerCard } from "@/types/api"

const districts = ["Tümü", "Vinewood", "Vespucci", "Del Perro"] as const
const levels = ["Tümü", "Standard", "Premium"] as const

const label = (value: string) => value.replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase())

const formatBookingDate = (value?: number | string) => {
  if (value === undefined) return "Zamanlanmadı"
  const epoch = typeof value === "number" ? (value < 100_000_000_000 ? value * 1000 : value) : value
  const date = new Date(epoch)
  return Number.isNaN(date.getTime()) ? String(value) : date.toLocaleString("tr-TR", { dateStyle: "medium", timeStyle: "short" })
}

const statusLabel: Record<ClientBooking["status"], string> = {
  DRAFT: "Taslak", QUOTED: "Teklif hazır", OFFERED: "Teklif gönderildi", ACCEPTED: "Kabul edildi",
  RESERVED: "Rezerve", TRAVELLING: "Yolda", ARRIVED: "Ulaştı", ACTIVE: "Aktif", COMPLETED: "Tamamlandı",
  SETTLED: "Ödendi", DECLINED: "Reddedildi", CANCELLED: "İptal", EXPIRED: "Süresi doldu", INTERRUPTED: "Kesildi",
}

function BookingCard({ booking, featured = false }: { booking: ClientBooking; featured?: boolean }) {
  const amount = booking.amountMinor !== undefined ? `${booking.currency ?? ""}${booking.amountMinor}` : "—"
  return <Card className={`rounded-none border-border shadow-none ${featured ? "border-primary/60 bg-primary/5" : "bg-card"}`}>
    <CardHeader className="gap-3">
      <div className="flex items-start justify-between gap-3">
        <div><CardTitle className="text-lg font-normal tracking-[-0.02em]">{booking.workerName}</CardTitle><p className="mt-1 font-mono text-xs text-muted-foreground">#{booking.bookingId}</p></div>
        <Badge variant={booking.status === "ACTIVE" ? "default" : "secondary"} className="rounded-none tracking-[0.08em] uppercase">{statusLabel[booking.status]}</Badge>
      </div>
    </CardHeader>
    <CardContent className="grid grid-cols-2 gap-3 border-y border-border py-4 text-sm">
      <div><span className="block text-xs tracking-[0.12em] text-muted-foreground uppercase">Zaman</span><span className="mt-1 block">{formatBookingDate(booking.scheduledAt ?? booking.completedAt)}</span></div>
      <div><span className="block text-xs tracking-[0.12em] text-muted-foreground uppercase">Tutar</span><span className="mt-1 block tabular-nums">{amount}</span></div>
      {booking.etaMinutes !== undefined && <div><span className="block text-xs tracking-[0.12em] text-muted-foreground uppercase">ETA</span><span className="mt-1 block tabular-nums">{booking.etaMinutes} dk</span></div>}
      {booking.meetingMode && <div><span className="block text-xs tracking-[0.12em] text-muted-foreground uppercase">Buluşma</span><span className="mt-1 block">{label(booking.meetingMode)}</span></div>}
    </CardContent>
  </Card>
}

export default function App() {
  // Production NUI starts hidden; only the client visibility event may open it.
  // Keep the browser-only Vite preview usable during local development.
  const previewVisible = import.meta.env.DEV && typeof window.GetParentResourceName !== "function"
  const [visible, setVisible] = useState(previewVisible)
  const [workers, setWorkers] = useState<WorkerCard[]>([])
  const [district, setDistrict] = useState<(typeof districts)[number]>("Tümü")
  const [level, setLevel] = useState<(typeof levels)[number]>("Tümü")
  const [worker, setWorker] = useState<WorkerCard | null>(null)
  const [draft, setDraft] = useState<BookingDraft | null>(null)
  const [quote, setQuote] = useState<PriceQuote | null>(null)
  const [loading, setLoading] = useState(true)
  const [pending, setPending] = useState(false)
  const [message, setMessage] = useState<string | null>(null)
  const [bookingPage, setBookingPage] = useState<ClientBookingPage | null>(null)
  const [bookingsLoading, setBookingsLoading] = useState(true)
  const [bookingError, setBookingError] = useState<string | null>(null)

  const loadBookings = useCallback(() => {
    setBookingsLoading(true)
    void nuiRequest("client-bookings:list", { limit: 5, offset: 0 }).then((result) => {
      setBookingsLoading(false)
      if (result.ok) {
        setBookingPage(result.value)
        setBookingError(null)
      } else {
        setBookingError(result.error.message)
      }
    })
  }, [])

  useEffect(() => {
    let mounted = true
    setLoading(true)
    void nuiRequest("marketplace:list", {
      district: district === "Tümü" ? undefined : district,
      priceClass: level === "Tümü" ? undefined : level.toLowerCase() as "standard" | "premium",
    }).then((result) => {
      if (!mounted) return
      setLoading(false)
      if (result.ok) {
        setWorkers(result.value.items)
        setMessage(null)
      } else {
        setMessage(result.error.message)
      }
    })
    return () => { mounted = false }
  }, [district, level])

  useEffect(() => {
    loadBookings()
  }, [loadBookings])

  useEffect(() => {
    const receiveMessage = (event: MessageEvent<{ type?: string; visible?: boolean }>) => {
      if (event.data?.type === "nightshift:visibility") setVisible(event.data.visible === true)
    }
    window.addEventListener("message", receiveMessage)
    return () => window.removeEventListener("message", receiveMessage)
  }, [])

  useEffect(() => {
    const documentRoot = document.documentElement
    documentRoot.dataset.nuiVisible = visible ? "true" : "false"
    return () => { documentRoot.dataset.nuiVisible = "false" }
  }, [visible])

  const selectWorker = (candidate: WorkerCard) => {
    setWorker(candidate)
    setQuote(null)
    setMessage(null)
    setDraft({ workerId: candidate.workerId, packageId: candidate.packages[0], meetingMode: "come_to_me", locationId: "configured_default" })
  }

  const requestQuote = async () => {
    if (!draft) return
    setPending(true)
    const result = await nuiRequest("booking:quote", draft)
    setPending(false)
    if (result.ok) {
      setQuote(result.value)
      setMessage(null)
    } else {
      setMessage(result.error.message)
    }
  }

  const confirm = async () => {
    if (!quote) return
    setPending(true)
    const result = await nuiRequest("booking:confirm", { quoteId: quote.quoteId })
    setPending(false)
    if (result.ok) {
      setMessage(`Booking #${result.value.bookingId} rezerve edildi.`)
      setQuote(null)
      setWorker(null)
      setDraft(null)
      loadBookings()
    } else {
      setMessage(result.error.message)
    }
  }

  const close = () => {
    setVisible(false)
    void nuiRequest("ui:close", {})
  }

  if (!visible) return null

  return (
    <main className="mx-auto min-h-screen max-w-6xl px-4 py-4 md:px-8 md:py-8">
      <section className="border border-border bg-background shadow-[0_24px_60px_rgba(0,0,0,0.28)]">
        <header className="grid grid-cols-12 gap-4 border-b border-border px-4 py-5 md:gap-8 md:px-8 md:py-6">
          <div className="col-span-12 flex items-start justify-between gap-4 md:col-span-7">
            <div className="flex flex-col gap-3">
              <span className="flex items-center gap-3 text-xs tracking-[0.18em] text-muted-foreground uppercase"><span className="size-2 bg-primary" />NightShift</span>
              <h1 className="text-balance text-3xl leading-none font-light tracking-[-0.03em] text-foreground md:text-5xl">Şehirdeki uygun seçenekler.</h1>
            </div>
            <Button variant="ghost" size="icon" aria-label="Arayüzü kapat" onClick={close}><XIcon /></Button>
          </div>
          <p className="col-span-12 max-w-[60ch] self-end text-sm leading-relaxed text-muted-foreground md:col-span-5">Canlı uygunluk ve nihai fiyat her zaman sunucudan gelir. Bir worker seç, isteğini oluştur, süreli teklifi onayla.</p>
       </header>

        <section className="border-b border-border px-4 py-5 md:px-8 md:py-6" aria-labelledby="booking-heading">
          <div className="mb-4 flex items-end justify-between gap-4"><div><h2 id="booking-heading" className="text-xl leading-tight font-normal tracking-[-0.02em] text-foreground">Rezervasyonlar</h2><p className="mt-1 text-sm text-muted-foreground">Aktif, yaklaşan ve geçmiş isteklerin.</p></div><Button variant="outline" className="min-h-10 rounded-none" onClick={loadBookings} disabled={bookingsLoading}>{bookingsLoading ? "Yükleniyor…" : "Yenile"}</Button></div>
          {bookingsLoading && <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">{[1, 2, 3].map((item) => <Skeleton key={item} className="h-40 rounded-none bg-muted" />)}</div>}
          {!bookingsLoading && bookingError && <p className="border border-border bg-muted p-4 text-sm leading-relaxed text-muted-foreground">{bookingError}</p>}
          {!bookingsLoading && !bookingError && bookingPage && <div className="flex flex-col gap-5">
            {bookingPage.current ? <div><div className="mb-2 flex items-center gap-2"><span className="size-2 bg-primary" /><span className="text-xs tracking-[0.16em] text-muted-foreground uppercase">Şu an</span></div><BookingCard booking={bookingPage.current} featured /></div> : <p className="border border-dashed border-border p-4 text-sm text-muted-foreground">Aktif rezervasyon yok.</p>}
            {bookingPage.upcoming.length > 0 && <div><div className="mb-2 flex items-center gap-2"><span className="size-2 bg-muted-foreground" /><span className="text-xs tracking-[0.16em] text-muted-foreground uppercase">Yaklaşan</span></div><div className="grid grid-cols-1 gap-4 lg:grid-cols-2">{bookingPage.upcoming.map((item) => <BookingCard key={item.bookingId} booking={item} />)}</div></div>}
            {bookingPage.history.length > 0 && <div><div className="mb-2 flex items-center gap-2"><span className="size-2 bg-muted-foreground" /><span className="text-xs tracking-[0.16em] text-muted-foreground uppercase">Geçmiş · {bookingPage.total}</span></div><div className="grid grid-cols-1 gap-4 lg:grid-cols-3">{bookingPage.history.map((item) => <BookingCard key={item.bookingId} booking={item} />)}</div></div>}
            {!bookingPage.current && bookingPage.upcoming.length === 0 && bookingPage.history.length === 0 && <p className="border border-border p-6 text-sm leading-relaxed text-muted-foreground">Henüz rezervasyon kaydı yok. Marketplace listesinden bir worker seçerek başlayabilirsin.</p>}
          </div>}
        </section>

        <div className="grid grid-cols-12 gap-4 px-4 py-5 md:gap-8 md:px-8 md:py-6">
          <aside className="col-span-12 flex flex-col gap-5 md:col-span-3">
            <div className="flex flex-col gap-2"><span className="text-xs tracking-[0.16em] text-muted-foreground uppercase">Bölge</span><ToggleGroup value={[district]} onValueChange={(value) => value[0] && setDistrict(value[0] as (typeof districts)[number])} spacing={0} className="w-full flex-wrap">{districts.map((item) => <ToggleGroupItem key={item} value={item} variant="outline" className="min-h-11 grow">{item}</ToggleGroupItem>)}</ToggleGroup></div>
            <div className="flex flex-col gap-2"><span className="text-xs tracking-[0.16em] text-muted-foreground uppercase">Seviye</span><ToggleGroup value={[level]} onValueChange={(value) => value[0] && setLevel(value[0] as (typeof levels)[number])} spacing={0} className="w-full flex-wrap">{levels.map((item) => <ToggleGroupItem key={item} value={item} variant="outline" className="min-h-11 grow">{item}</ToggleGroupItem>)}</ToggleGroup></div>
            <Separator />
            <div className="flex items-start gap-3 text-sm leading-relaxed text-muted-foreground"><ShieldCheckIcon className="mt-0.5 shrink-0" /><p>Liste yalnızca herkese açık worker kartlarını gösterir. Özel profil ve ödeme verisi tarayıcıya verilmez.</p></div>
          </aside>

          <section className="col-span-12 md:col-span-9" aria-live="polite">
            <div className="mb-4 flex items-end justify-between gap-4"><div><h2 className="text-xl leading-tight font-normal tracking-[-0.02em] text-foreground">Marketplace</h2><p className="mt-1 text-sm text-muted-foreground">{loading ? "Uygunluk yenileniyor…" : `${workers.length} uygun worker`}</p></div><Badge variant="secondary" className="rounded-none tracking-[0.12em] uppercase">Canlı durum</Badge></div>
            {message && <p className="mb-4 border border-border bg-muted p-3 text-sm leading-relaxed">{message}</p>}
            {loading && <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">{[1, 2, 3, 4].map((item) => <Skeleton key={item} className="h-64 rounded-none bg-muted" />)}</div>}
            {!loading && !workers.length && <p className="border border-border p-8 text-sm leading-relaxed text-muted-foreground">Bu filtrelerle eşleşen uygun worker yok. Bölge veya seviye seçimini değiştir.</p>}
            {!loading && workers.length > 0 && <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">{workers.map((candidate) => <Card key={candidate.workerId} className="rounded-none border border-border bg-card shadow-none"><CardHeader><div className="flex items-center gap-3"><Avatar size="lg" className="rounded-none bg-secondary"><AvatarFallback className="rounded-none font-mono text-xs text-foreground">{candidate.initials}</AvatarFallback></Avatar><div><CardTitle className="text-lg font-normal tracking-[-0.02em]">{candidate.displayName}</CardTitle><p className="mt-1 flex items-center gap-1 text-sm text-muted-foreground"><MapPinIcon />{candidate.district}</p></div></div><CardAction><Badge variant={candidate.priceClass === "premium" ? "default" : "secondary"} className="rounded-none tracking-[0.12em] uppercase">{candidate.priceClass}</Badge></CardAction></CardHeader><CardContent className="flex flex-col gap-4"><div className="grid grid-cols-3 gap-2 border-y border-border py-3 text-sm tabular-nums"><div><span className="block text-xs tracking-[0.12em] text-muted-foreground uppercase">Başlangıç</span><span className="mt-1 block font-medium">${candidate.startingPrice}</span></div><div><span className="block text-xs tracking-[0.12em] text-muted-foreground uppercase">Puan</span><span className="mt-1 flex items-center gap-1 font-medium"><StarIcon />{candidate.rating}</span></div><div><span className="block text-xs tracking-[0.12em] text-muted-foreground uppercase">ETA</span><span className="mt-1 flex items-center gap-1 font-medium"><Clock3Icon />{candidate.etaMinutes} dk</span></div></div><p className="text-sm leading-relaxed text-muted-foreground">{candidate.ratingCount} değerlendirme · {candidate.packages.map(label).join(" / ")}</p></CardContent><CardFooter className="rounded-none border-border bg-transparent px-4 py-4"><Button className="min-h-11 w-full" onClick={() => selectWorker(candidate)}>İstek oluştur<ArrowRightIcon data-icon="inline-end" /></Button></CardFooter></Card>)}</div>}
          </section>
        </div>
      </section>

      <Sheet open={Boolean(worker)} onOpenChange={(open) => !open && setWorker(null)}><SheetContent side="right" className="w-full border-border bg-popover sm:max-w-md"><SheetHeader className="border-b border-border p-6"><SheetTitle className="text-2xl font-light tracking-[-0.03em]">Booking isteği</SheetTitle><SheetDescription>{worker ? `${worker.displayName} için süreli teklif al.` : ""}</SheetDescription></SheetHeader>{worker && draft && <div className="flex flex-1 flex-col gap-6 overflow-y-auto p-6"><div className="flex items-center justify-between border-y border-border py-4 text-sm"><span className="text-muted-foreground">Seçilen worker</span><span>{worker.displayName}</span></div><div className="flex flex-col gap-2"><span className="text-xs tracking-[0.16em] text-muted-foreground uppercase">Paket</span><ToggleGroup value={[draft.packageId]} onValueChange={(value) => value[0] && setDraft({ ...draft, packageId: value[0] })} spacing={0} className="w-full flex-wrap">{worker.packages.map((item) => <ToggleGroupItem key={item} value={item} variant="outline" className="min-h-11 grow">{label(item)}</ToggleGroupItem>)}</ToggleGroup></div><div className="flex flex-col gap-2"><span className="text-xs tracking-[0.16em] text-muted-foreground uppercase">Buluşma biçimi</span><ToggleGroup value={[draft.meetingMode]} onValueChange={(value) => value[0] && setDraft({ ...draft, meetingMode: value[0] as BookingDraft["meetingMode"] })} spacing={0} className="w-full flex-wrap"><ToggleGroupItem value="come_to_me" variant="outline" className="min-h-11 grow">Gel</ToggleGroupItem><ToggleGroupItem value="pickup" variant="outline" className="min-h-11 grow">Al</ToggleGroupItem><ToggleGroupItem value="meet_there" variant="outline" className="min-h-11 grow">Buluş</ToggleGroupItem></ToggleGroup></div>{quote ? <div className="border border-primary/50 bg-primary/10 p-4"><span className="text-xs tracking-[0.16em] text-muted-foreground uppercase">Sunucu teklifi</span><div className="mt-2 flex items-end justify-between"><strong className="text-3xl font-light tabular-nums">{quote.currency}{quote.amount}</strong><span className="text-sm text-muted-foreground">{new Date(quote.expiresAt).toLocaleTimeString("tr-TR", { hour: "2-digit", minute: "2-digit" })}’e kadar</span></div></div> : <p className="text-sm leading-relaxed text-muted-foreground">Teklif tutarı, seçimin ve anlık uygunluğun sunucu tarafındaki hesabından gelir.</p>}<div className="mt-auto flex flex-col gap-3"><Button className="min-h-11" disabled={pending} onClick={() => void requestQuote()}>{pending && <Spinner data-icon="inline-start" />}Teklif al</Button>{quote && <Button variant="outline" className="min-h-11" disabled={pending} onClick={() => void confirm()}>{pending && <Spinner data-icon="inline-start" />}Teklifi onayla</Button>}</div></div>}</SheetContent></Sheet>
    </main>
  )
}
