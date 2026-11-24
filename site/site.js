// Two small things, both optional: the clock in the margin runs as you scroll, and W plays
// "What did they say?" on the picture. Without this file the page reads the same.
(() => {
  document.documentElement.classList.add("js");
  const still = matchMedia("(prefers-reduced-motion: reduce)");

  // The clock: each scene runs from its minute towards the next one's.
  const minutes = (t) => { const [h, m] = t.split(":").map(Number); return h * 60 + m; };
  const scenes = [...document.querySelectorAll(".scene[data-from]")].map((el) => {
    const time = el.querySelector(".clock time");
    const face = document.createElement("span");
    face.setAttribute("aria-hidden", "true");
    face.textContent = time.textContent;
    time.classList.add("sr");
    time.after(face);
    return { el, face, from: minutes(el.dataset.from), to: minutes(el.dataset.to) };
  });
  let waiting = false;
  const tick = () => {
    waiting = false;
    for (const s of scenes) {
      const box = s.el.getBoundingClientRect();
      if (box.bottom < 0 || box.top > innerHeight) continue;
      const p = still.matches ? 0 : Math.min(1, Math.max(0, -box.top / Math.max(1, box.height - innerHeight * 0.5)));
      const m = Math.min(s.to - 1, Math.floor(s.from + p * (s.to - s.from)));
      const text = `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
      if (s.face.textContent !== text) s.face.textContent = text;
    }
  };
  addEventListener("scroll", () => { if (!waiting) { waiting = true; requestAnimationFrame(tick); } }, { passive: true });
  tick();

  // W
  const key = document.getElementById("w"), say = document.getElementById("say"), said = document.getElementById("said");
  if (!key || !say) return;
  key.hidden = false;
  key.setAttribute("aria-label", "W, what did they say?");
  let timer;
  const off = () => { say.classList.remove("on"); key.setAttribute("aria-pressed", "false"); };
  const on = () => {
    clearTimeout(timer);
    say.classList.add("on");
    key.setAttribute("aria-pressed", "true");
    said.textContent = "";
    requestAnimationFrame(() => { said.textContent = "Ten seconds back, subtitles on: What brings you to the land of the gatekeepers?"; });
    timer = setTimeout(off, 6000);
  };
  key.setAttribute("aria-pressed", "false");
  key.addEventListener("click", on);
  addEventListener("keydown", (e) => {
    if (e.key.toLowerCase() !== "w" || e.metaKey || e.ctrlKey || e.altKey || e.repeat) return;
    if (/^(input|textarea|select)$/i.test(document.activeElement?.tagName ?? "")) return;
    const box = say.getBoundingClientRect();
    if (box.bottom > 0 && box.top < innerHeight) on();
  });
})();
