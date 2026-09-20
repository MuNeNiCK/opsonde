import { BookOpenCheck, Boxes, FileText, RadioTower, Settings, ShieldCheck } from "lucide-react";
import { useTranslation } from "react-i18next";
import { NavLink, Outlet, useLocation } from "react-router-dom";
import { useAuthentication } from "@/auth/context";
import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarInset,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarProvider,
  SidebarTrigger,
} from "@/components/ui/sidebar";

const navigation = [
  {
    label: "navigation.operations",
    items: [
      ["/cases", "navigation.cases", RadioTower],
      ["/audits", "navigation.audits", ShieldCheck],
      ["/reports", "navigation.reports", FileText],
    ],
  },
  {
    label: "navigation.configuration",
    items: [
      ["/targets", "navigation.targets", Boxes],
      ["/settings", "navigation.setup", Settings],
    ],
  },
] as const;

export function AppShell() {
  const { account, signOut } = useAuthentication();
  const { t, i18n } = useTranslation();
  const location = useLocation();
  const initials = account?.email.slice(0, 2).toUpperCase() ?? "OP";
  const setLanguage = (language: string) => void i18n.changeLanguage(language);

  return (
    <SidebarProvider>
      <Sidebar collapsible="icon">
        <SidebarHeader>
          <div className="flex h-10 items-center gap-2 px-2 font-semibold">
            <BookOpenCheck className="size-5 text-primary" />
            <span className="group-data-[collapsible=icon]:hidden">Opsonde</span>
          </div>
        </SidebarHeader>
        <SidebarContent>
          {navigation.map((section) => (
            <SidebarGroup key={section.label}>
              <SidebarGroupLabel>{t(section.label)}</SidebarGroupLabel>
              <SidebarGroupContent>
                <SidebarMenu>
                  {section.items.map(([to, label, Icon]) => (
                    <SidebarMenuItem key={to}>
                      <SidebarMenuButton
                        asChild
                        isActive={
                          location.pathname === to || location.pathname.startsWith(`${to}/`)
                        }
                        tooltip={t(label)}
                      >
                        <NavLink to={to}>
                          <Icon />
                          <span>{t(label)}</span>
                        </NavLink>
                      </SidebarMenuButton>
                    </SidebarMenuItem>
                  ))}
                </SidebarMenu>
              </SidebarGroupContent>
            </SidebarGroup>
          ))}
        </SidebarContent>
        <SidebarFooter>
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button variant="ghost" className="h-auto w-full justify-start gap-2 p-2">
                <Avatar size="sm">
                  <AvatarFallback>{initials}</AvatarFallback>
                </Avatar>
                <span className="min-w-0 truncate group-data-[collapsible=icon]:hidden">
                  {account?.email}
                </span>
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent side="top" align="start" className="min-w-56">
              <DropdownMenuLabel>{account?.email}</DropdownMenuLabel>
              <DropdownMenuSeparator />
              <DropdownMenuItem onClick={() => void signOut()}>
                {t("common.signOut")}
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </SidebarFooter>
      </Sidebar>
      <SidebarInset>
        <header className="flex h-14 items-center justify-between border-b px-4">
          <SidebarTrigger />
          <div className="flex items-center gap-2 text-sm text-muted-foreground">
            <span>{t("common.language")}</span>
            <Button
              size="sm"
              variant="outline"
              onClick={() => setLanguage(i18n.resolvedLanguage === "ja" ? "en" : "ja")}
              aria-label={t("common.language")}
            >
              {i18n.resolvedLanguage === "ja" ? "EN" : "日本語"}
            </Button>
          </div>
        </header>
        <Outlet />
      </SidebarInset>
    </SidebarProvider>
  );
}
