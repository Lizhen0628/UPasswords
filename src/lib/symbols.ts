// Card symbol catalog — mirrors Models/SymbolModel.swift: the original symbol
// vocabulary (46 TIFF assets) drawn here with lucide equivalents. Symbol names,
// groups and colors match the original; artwork is independently drawn.
import type { Component } from "vue";
import { db as dbLookup } from "./i18n";
import {
  Globe, Mail, Router, Network, Cloud,
  MessageCircle, AtSign, Camera, Send, Phone, Music, Music2, Tv,
  MessageSquare, Pin, ShoppingCart, Tag, CircleDollarSign, CreditCard,
  ShoppingBag, Blocks, BookOpen, ShieldCheck, Landmark, Wallet, Banknote,
  Bitcoin, Coins, TrendingUp, Umbrella, ChartColumn, Percent,
  ArrowLeftRight, PiggyBank, Contact, Book, Car, User, MapPin, Gift, Users,
  HeartPulse, Stethoscope, Pill, PawPrint, Shirt, KeyRound, Lock, Disc, Usb,
  Monitor, Laptop, Smartphone, Tablet, Printer, Gamepad2, RadioTower,
  Server, Database, Code, Bike, Bus, TrainFront, Plane, Ship, Fuel, Map, Bed,
  Luggage, Shield, Fingerprint, Eye, LockKeyhole, AlarmClock, Video, Siren,
  BadgeCheck, Layers, StickyNote, Bookmark, GraduationCap,
  Film, Dumbbell, PlaneTakeoff, Utensils, Coffee,
  Briefcase, Presentation, Scale, Atom, CloudSun, Recycle, SquarePlus, Star,
  Heart, Flag, TriangleAlert, CircleCheck, CircleHelp, Info, Settings, Link,
  SquareDashed, Play, GitBranch, GitFork, ThumbsUp,
  LayoutGrid, PanelLeft, CircleX, Share, CirclePlus, WandSparkles,
  SlidersHorizontal, Ellipsis, Pencil, ChevronUp, ChevronDown, ChevronRight,
  Check, Clock, Copy, Timer, Hourglass, CalendarX, Archive, Trash, File,
  Image, RefreshCw, ArrowUpDown, Plus, ShieldAlert, Search, EyeOff, Download,
  History, Paintbrush, SquareCheck, Square, Circle, ListTree, Wrench,
  Paperclip, X, House, Moon,
} from "@lucide/vue";

// icon name → component (explicit imports keep the bundle tree-shaken)
const registry: Record<string, Component> = {
  globe: Globe, mail: Mail, router: Router, network: Network, cloud: Cloud,
  "message-circle": MessageCircle, "at-sign": AtSign, camera: Camera, send: Send, phone: Phone,
  music: Music, "music-2": Music2, tv: Tv, "git-branch": GitBranch, "git-fork": GitFork,
  "thumbs-up": ThumbsUp, play: Play,
  "message-square": MessageSquare, pin: Pin,
  "shopping-cart": ShoppingCart, tag: Tag, "circle-dollar-sign": CircleDollarSign,
  "credit-card": CreditCard, "shopping-bag": ShoppingBag, blocks: Blocks,
  "book-open": BookOpen, "shield-check": ShieldCheck, landmark: Landmark,
  wallet: Wallet, banknote: Banknote, bitcoin: Bitcoin, coins: Coins,
  "trending-up": TrendingUp, umbrella: Umbrella, "chart-column": ChartColumn,
  percent: Percent, "arrow-left-right": ArrowLeftRight, "piggy-bank": PiggyBank,
  contact: Contact, book: Book, car: Car, user: User, "map-pin": MapPin,
  gift: Gift, users: Users, "heart-pulse": HeartPulse, stethoscope: Stethoscope,
  pill: Pill, "paw-print": PawPrint, shirt: Shirt, "key-round": KeyRound,
  lock: Lock, disc: Disc, usb: Usb, monitor: Monitor, laptop: Laptop,
  smartphone: Smartphone, tablet: Tablet, printer: Printer,
  "gamepad-2": Gamepad2, "radio-tower": RadioTower, server: Server,
  database: Database, code: Code, bike: Bike, bus: Bus, "train-front": TrainFront,
  plane: Plane, ship: Ship, fuel: Fuel, map: Map, bed: Bed, luggage: Luggage,
  shield: Shield, fingerprint: Fingerprint, eye: Eye, "lock-keyhole": LockKeyhole,
  "alarm-clock": AlarmClock, video: Video, siren: Siren, "badge-check": BadgeCheck,
  layers: Layers, "sticky-note": StickyNote, bookmark: Bookmark,
  "graduation-cap": GraduationCap, film: Film, dumbbell: Dumbbell,
  "plane-takeoff": PlaneTakeoff, utensils: Utensils, coffee: Coffee, wrench: Wrench,
  briefcase: Briefcase, presentation: Presentation, scale: Scale, atom: Atom,
  "cloud-sun": CloudSun, recycle: Recycle, "square-plus": SquarePlus, star: Star,
  heart: Heart, flag: Flag, "triangle-alert": TriangleAlert,
  "circle-check": CircleCheck, "circle-help": CircleHelp, info: Info,
  settings: Settings, link: Link, "square-dashed": SquareDashed,
  // UI chrome icons (sidebar / toolbar / fields / sheets)
  "layout-grid": LayoutGrid, "panel-left": PanelLeft, "circle-x": CircleX, house: House, moon: Moon,
  share: Share, "circle-plus": CirclePlus, "wand-sparkles": WandSparkles,
  "sliders-horizontal": SlidersHorizontal, ellipsis: Ellipsis, pencil: Pencil,
  "chevron-up": ChevronUp, "chevron-down": ChevronDown, "chevron-right": ChevronRight,
  check: Check, clock: Clock, copy: Copy, timer: Timer, hourglass: Hourglass,
  "calendar-x": CalendarX, archive: Archive, trash: Trash, file: File,
  image: Image, "refresh-cw": RefreshCw, "arrow-up-down": ArrowUpDown, plus: Plus,
  "shield-alert": ShieldAlert, search: Search, "eye-off": EyeOff, download: Download,
  history: History, paintbrush: Paintbrush, "square-check": SquareCheck,
  square: Square, circle: Circle, "list-tree": ListTree,
  paperclip: Paperclip, x: X,
};

export function icon(name: string): Component {
  return registry[name] ?? SquareDashed;
}

/** Original symbol names → lucide icon names (SymbolModel.sfSymbol equivalent). */
interface SymbolEntry {
  name: string;
  icon: string;
}

const CATALOG: { group: string; items: SymbolEntry[] }[] = [
  { group: "internet_group", items: [
    { name: "web_site", icon: "globe" }, { name: "email", icon: "mail" },
    { name: "router", icon: "router" }, { name: "network", icon: "network" },
    { name: "cloud", icon: "cloud" }, { name: "facebook", icon: "thumbs-up" },
    { name: "x_twitter", icon: "at-sign" }, { name: "instagram", icon: "camera" },
    { name: "linkedin", icon: "briefcase" }, { name: "reddit", icon: "message-circle" },
    { name: "youtube", icon: "play" }, { name: "telegram", icon: "send" },
    { name: "whatsapp", icon: "phone" }, { name: "tiktok", icon: "music" },
    { name: "netflix", icon: "tv" }, { name: "spotify", icon: "music-2" },
    { name: "twitch", icon: "tv" }, { name: "github", icon: "git-branch" },
    { name: "gitlab", icon: "git-fork" }, { name: "discord", icon: "message-square" },
    { name: "pinterest", icon: "pin" }, { name: "amazon", icon: "shopping-cart" },
    { name: "ebay", icon: "tag" }, { name: "paypal", icon: "circle-dollar-sign" },
    { name: "stripe", icon: "credit-card" }, { name: "shop", icon: "shopping-bag" },
    { name: "wordpress", icon: "blocks" }, { name: "wikipedia", icon: "book-open" },
    { name: "vpn", icon: "shield-check" },
  ] },
  { group: "finances_group", items: [
    { name: "bank", icon: "landmark" }, { name: "credit_card", icon: "credit-card" },
    { name: "wallet", icon: "wallet" }, { name: "cash", icon: "banknote" },
    { name: "money", icon: "circle-dollar-sign" }, { name: "bitcoin", icon: "bitcoin" },
    { name: "coin", icon: "coins" }, { name: "investment", icon: "trending-up" },
    { name: "insurance", icon: "umbrella" }, { name: "stock", icon: "chart-column" },
    { name: "tax", icon: "percent" }, { name: "loan", icon: "arrow-left-right" },
    { name: "piggy_bank", icon: "piggy-bank" }, { name: "visa", icon: "credit-card" },
    { name: "mastercard", icon: "credit-card" }, { name: "amex", icon: "credit-card" },
    { name: "discover", icon: "credit-card" }, { name: "jcb", icon: "credit-card" },
    { name: "rupay", icon: "credit-card" },
  ] },
  { group: "personal_group", items: [
    { name: "id", icon: "contact" }, { name: "passport", icon: "book" },
    { name: "driving_license", icon: "car" }, { name: "social_security", icon: "user" },
    { name: "name", icon: "user" }, { name: "address", icon: "map-pin" },
    { name: "birthday", icon: "gift" }, { name: "phone", icon: "phone" },
    { name: "contacts", icon: "users" }, { name: "family", icon: "users" },
    { name: "health", icon: "heart-pulse" }, { name: "doctor", icon: "stethoscope" },
    { name: "medicine", icon: "pill" }, { name: "pets", icon: "paw-print" },
    { name: "clothes", icon: "shirt" },
  ] },
  { group: "technology_group", items: [
    { name: "key", icon: "key-round" }, { name: "lock", icon: "lock" },
    { name: "cd", icon: "disc" }, { name: "usb", icon: "usb" },
    { name: "computer", icon: "monitor" }, { name: "laptop", icon: "laptop" },
    { name: "mobile", icon: "smartphone" }, { name: "tablet", icon: "tablet" },
    { name: "tv", icon: "tv" }, { name: "camera", icon: "camera" },
    { name: "printer", icon: "printer" }, { name: "console", icon: "gamepad-2" },
    { name: "drone", icon: "radio-tower" }, { name: "server", icon: "server" },
    { name: "database", icon: "database" }, { name: "code", icon: "code" },
  ] },
  { group: "transport_group", items: [
    { name: "car", icon: "car" }, { name: "moto", icon: "bike" },
    { name: "bicycle", icon: "bike" }, { name: "bus", icon: "bus" },
    { name: "train", icon: "train-front" }, { name: "plane", icon: "plane" },
    { name: "ship", icon: "ship" }, { name: "transport", icon: "car" },
    { name: "fuel", icon: "fuel" }, { name: "map", icon: "map" },
    { name: "hotel", icon: "bed" }, { name: "luggage", icon: "luggage" },
  ] },
  { group: "security_group", items: [
    { name: "shield", icon: "shield" }, { name: "fingerprint", icon: "fingerprint" },
    { name: "eye", icon: "eye" }, { name: "vault", icon: "lock-keyhole" },
    { name: "safe", icon: "lock" }, { name: "alarm", icon: "alarm-clock" },
    { name: "cctv", icon: "video" }, { name: "siren", icon: "siren" },
  ] },
  { group: "misc_group", items: [
    { name: "membership", icon: "badge-check" }, { name: "card", icon: "layers" },
    { name: "note", icon: "sticky-note" }, { name: "bookmark", icon: "bookmark" },
    { name: "gift", icon: "gift" }, { name: "education", icon: "graduation-cap" },
    { name: "book", icon: "book" }, { name: "music", icon: "music" },
    { name: "movie", icon: "film" }, { name: "game", icon: "gamepad-2" },
    { name: "sport", icon: "dumbbell" }, { name: "travel", icon: "plane-takeoff" },
    { name: "food", icon: "utensils" }, { name: "coffee", icon: "coffee" },
    { name: "shopping", icon: "shopping-bag" }, { name: "tools", icon: "wrench" },
    { name: "job", icon: "briefcase" }, { name: "meeting", icon: "users" },
    { name: "lecture", icon: "presentation" }, { name: "legal", icon: "scale" },
    { name: "science", icon: "atom" }, { name: "weather", icon: "cloud-sun" },
    { name: "recycle", icon: "recycle" }, { name: "custom", icon: "square-dashed" },
  ] },
  { group: "special_group", items: [
    { name: "star", icon: "star" }, { name: "heart", icon: "heart" },
    { name: "flag", icon: "flag" }, { name: "warning", icon: "triangle-alert" },
    { name: "check", icon: "circle-check" }, { name: "question", icon: "circle-help" },
    { name: "info", icon: "info" }, { name: "plus", icon: "square-plus" },
    { name: "gear", icon: "settings" }, { name: "link", icon: "link" },
    { name: "pin", icon: "map-pin" },
  ] },
];

const nameToIcon: Record<string, string> = {};
const groupMap: Record<string, string[]> = {};
for (const g of CATALOG) {
  groupMap[g.group] = g.items.map((i) => i.name);
  for (const item of g.items) nameToIcon[item.name] = item.icon;
}

export const SYMBOL_GROUPS = CATALOG.map((g) => g.group);

export function symbolNamesForGroup(group: string): string[] {
  return groupMap[group] ?? [];
}

export function iconNameForSymbol(symbol: string): string {
  return nameToIcon[symbol] ?? "square-dashed";
}

export function allSymbolNames(): string[] {
  return Object.keys(nameToIcon);
}

export function groupLocalizedName(key: string): string {
  // group keys are database.strings keys like internet_group
  return dbLookup(key);
}

/** SymbolModel.creditCardSymbolForNumber: — brand detection by IIN. */
export function creditCardSymbolForNumber(number: string): string {
  const digits = number.replace(/\D/g, "");
  if (digits.length < 2) return "credit_card";
  const prefix2 = parseInt(digits.slice(0, 2), 10) || 0;
  const prefix4 = parseInt(digits.slice(0, 4), 10) || 0;
  const prefix3 = parseInt(digits.slice(0, 3), 10) || 0;
  if (digits.startsWith("4")) return "visa";
  if ((prefix2 >= 51 && prefix2 <= 55) || (prefix4 >= 2221 && prefix4 <= 2720)) return "mastercard";
  if (prefix2 === 34 || prefix2 === 37) return "amex";
  if (prefix2 === 60 || prefix2 === 65 || digits.startsWith("6011") || (prefix2 >= 644 && prefix2 <= 649))
    return "discover";
  if (prefix2 === 35 || (prefix3 >= 300 && prefix3 <= 305)) return "jcb";
  if (digits.startsWith("6035")) return "rupay";
  return "credit_card";
}
