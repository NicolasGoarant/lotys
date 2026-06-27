import { Controller } from "@hotwired/stimulus"

// Auto-disparition d'un message flash après un délai, avec fondu.
// Branché UNIQUEMENT sur les notices (succès) côté layouts — les alertes
// (erreurs) restent affichées jusqu'à navigation pour laisser le temps de
// les lire.
//
// Usage :
//   <div data-controller="flash"
//        style="transition: opacity 400ms ease">…</div>
//
// Personnalisation optionnelle :
//   data-flash-delay-value (ms avant fondu, défaut 4000)
//   data-flash-fade-value  (ms de la transition opacity, défaut 800)
//
// La courbe (ease-out) est portée par l'inline-style du <div> côté layout
// pour rester lisible et applicable sans JS — voir application.html.erb /
// devise.html.erb.
export default class extends Controller {
  static values = {
    delay: { type: Number, default: 4000 },
    fade:  { type: Number, default: 800 }
  }

  connect() {
    this.fadeTimer = setTimeout(() => {
      this.element.style.opacity = "0"
      this.removeTimer = setTimeout(() => this.element.remove(), this.fadeValue)
    }, this.delayValue)
  }

  disconnect() {
    clearTimeout(this.fadeTimer)
    clearTimeout(this.removeTimer)
  }
}
