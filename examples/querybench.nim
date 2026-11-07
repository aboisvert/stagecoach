import std/[strutils]
import cgi
import stagecoach/[flow, httpserver]

proc skuByteSum(sku: string): int =
  for c in sku:
    result += ord(c)

proc handle(ctx: HttpContext) {.flow.} =
  let target = ctx.getUri()
  let q = target.find('?')
  if q < 0:
    ctx.reply(Http400, "missing query")
    return
  if target[0 ..< q] != "/quote":
    ctx.reply(Http400, "expected path /quote")
    return
  let params = readData(target[q + 1 .. ^1])
  try:
    let qty = parseInt(params.getOrDefault("qty"))
    let unitCents = parseInt(params.getOrDefault("unit_cents"))
    let taxBps = parseInt(params.getOrDefault("tax_bps"))
    let sku = params.getOrDefault("sku")
    let subtotal = qty * unitCents
    let tax = subtotal * taxBps div 10_000
    let total = subtotal + tax
    let sum = skuByteSum(sku)
    ctx.reply(
      "sku=" & sku & " total_cents=" & $total & " sku_sum=" & $sum)
  except ValueError:
    ctx.reply(Http400, "bad integer parameter")

echo "Listening on http://127.0.0.1:8088 (GET /quote?...)"
let server = newHttpServer(loglevel = lvlError)
serve(server, 8088, handle)
wait(server)
