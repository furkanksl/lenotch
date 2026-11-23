(() => {
  let theme;
  try {
    theme = localStorage.getItem("lenotch-theme");
  } catch {
    // Fall back to the system preference if storage is blocked.
  }
  document.documentElement.classList.toggle(
    "dark",
    theme === "dark" || (!theme && matchMedia("(prefers-color-scheme: dark)").matches),
  );
})();
