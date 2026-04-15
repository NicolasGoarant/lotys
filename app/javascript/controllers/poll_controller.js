import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { url: String, interval: Number }

  connect() {
    this.timer = setInterval(() => this.check(), this.intervalValue || 3000)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  async check() {
    const res = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
    if (!res.ok) return
    const data = await res.json()
    if (data.status !== "analyzing") {
      clearInterval(this.timer)
      window.location.reload()
    }
  }
}
