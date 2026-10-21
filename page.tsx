import Link from "next/link";
import { createClient } from "@/lib/supabase/server";

export default async function Home() {
  const supabase = await createClient();
  const { data: tournaments } = await supabase
    .from("tournaments")
    .select("id,name,description,entry_fee,prize_description,status,capacity")
    .in("status", ["open", "upcoming"])
    .order("created_at", { ascending: false });

  return <>
    <header className="top">
      <Link className="logo" href="/">🎲 LUDO ARENA BD</Link>
      <nav className="row">
        <Link href="/wallet">ওয়ালেট</Link>
        <Link href="/account">অ্যাকাউন্ট</Link>
        <Link href="/admin">অ্যাডমিন</Link>
      </nav>
    </header>
    <section className="hero">
      <h1>আপনার লুডু দক্ষতা দেখান!</h1>
      <p className="muted">টুর্নামেন্ট দেখুন, নিয়ম পড়ুন এবং নিরাপদভাবে অংশগ্রহণের আবেদন করুন।</p>
      <Link href="/account"><button>লগইন / রেজিস্ট্রেশন</button></Link>
    </section>
    <main className="wrap">
      <h2>🏆 আসন্ন টুর্নামেন্ট</h2>
      <div className="grid">
        {(tournaments ?? []).map((t: any) => <article className="card" key={t.id}>
          <span className="pill">{t.status === "open" ? "রেজিস্ট্রেশন চলছে" : "শিগগিরই শুরু হবে"}</span>
          <h3>{t.name}</h3>
          <p className="muted">{t.description || "বিস্তারিত নিয়ম অ্যাডমিন প্রকাশ করবেন।"}</p>
          <p>এন্ট্রি ফি: ৳{(t.entry_fee / 100).toFixed(2)}</p>
          <p>পুরস্কার: {t.prize_description || "ঘোষণা হয়নি"}</p>
          <p>সর্বোচ্চ খেলোয়াড়: {t.capacity}</p>
          <Link href="/wallet"><button>পেমেন্ট / অংশগ্রহণ</button></Link>
        </article>)}
        {(!tournaments || tournaments.length === 0) && <div className="card">এখনো কোনো টুর্নামেন্ট প্রকাশিত হয়নি। অ্যাডমিন প্যানেল থেকে টুর্নামেন্ট যোগ করুন।</div>}
      </div>
      <div className="notice" style={{marginTop:24}}>
        নিরাপত্তা: মার্চেন্ট পেমেন্টের আবেদন অ্যাডমিন স্বাধীনভাবে যাচাই না করা পর্যন্ত ওয়ালেটে টাকা যোগ হবে না।
        নগদ পুরস্কার ও উত্তোলন চালুর আগে স্থানীয় আইন এবং পেমেন্ট প্রদানকারীর শর্ত যাচাই করুন।
      </div>
    </main>
    <footer>© 2026 Ludo Arena BD • Fair Play</footer>
  </>;
}
