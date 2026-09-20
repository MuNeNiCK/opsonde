import i18n from "i18next";
import { initReactI18next } from "react-i18next";
import en from "@/i18n/en";
import ja from "@/i18n/ja";

const localeKey = "opsonde.locale";
const storedLocale = localStorage.getItem(localeKey);
const defaultLocale =
  storedLocale === "ja" || storedLocale === "en"
    ? storedLocale
    : navigator.language.startsWith("ja")
      ? "ja"
      : "en";

void i18n.use(initReactI18next).init({
  resources: { en, ja },
  lng: defaultLocale,
  fallbackLng: "en",
  interpolation: { escapeValue: false },
});

i18n.on("languageChanged", (locale) => {
  const supportedLocale = locale.startsWith("ja") ? "ja" : "en";
  localStorage.setItem(localeKey, supportedLocale);
  document.documentElement.lang = supportedLocale;
});

document.documentElement.lang = defaultLocale;

export default i18n;
