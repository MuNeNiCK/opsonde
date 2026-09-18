import i18n from "i18next";
import { initReactI18next } from "react-i18next";

const localeKey = "opsonde.locale";
const storedLocale = localStorage.getItem(localeKey);
const defaultLocale =
  storedLocale === "ja" || storedLocale === "en"
    ? storedLocale
    : navigator.language.startsWith("ja")
      ? "ja"
      : "en";

const resources = {
  en: {
    translation: {
      common: { language: "Language", loading: "Loading", signOut: "Sign out" },
      login: {
        title: "Sign in to Opsonde",
        description: "Use your Opsonde account to continue.",
        email: "Email",
        password: "Password",
        submit: "Sign in",
        failed: "Email or password is invalid.",
      },
      navigation: {
        operations: "Operations",
        configuration: "Configuration",
        cases: "Cases",
        targets: "Targets",
        providers: "Providers",
        audits: "Audits",
        reports: "Reports",
        settings: "Settings",
      },
      pages: {
        cases: "Cases",
        case: "Case",
        targets: "Targets",
        providers: "Providers",
        audits: "Audits",
        reports: "Reports",
        settings: "Settings",
        foundation: "This workspace is ready for the connected product workflow.",
        notFound: "Page not found",
      },
    },
  },
  ja: {
    translation: {
      common: { language: "言語", loading: "読み込み中", signOut: "ログアウト" },
      login: {
        title: "Opsondeにログイン",
        description: "Opsondeアカウントで続行します。",
        email: "メールアドレス",
        password: "パスワード",
        submit: "ログイン",
        failed: "メールアドレスまたはパスワードが正しくありません。",
      },
      navigation: {
        operations: "運用",
        configuration: "設定",
        cases: "ケース",
        targets: "対象",
        providers: "プロバイダー",
        audits: "監査",
        reports: "レポート",
        settings: "設定",
      },
      pages: {
        cases: "ケース",
        case: "ケース",
        targets: "対象",
        providers: "プロバイダー",
        audits: "監査",
        reports: "レポート",
        settings: "設定",
        foundation: "接続済みの製品ワークフローを構成する準備ができています。",
        notFound: "ページが見つかりません",
      },
    },
  },
} as const;

void i18n.use(initReactI18next).init({
  resources,
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
