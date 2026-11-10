# Search tactics for Prince Solar Hub (SOLAR-216)

Research date: 2026-11-11.
State: home, privacy, terms indexed. 1 click, 14 impressions, avg position 4 (28 days). Not on page 1 for "SunSynk monitoring".

Not covered here (already being built): "SunSynk app alternative" page, comparison pages, help pages, SoftwareApplication + FAQ markup, sitemap.

Source quality: most 2026 sources are SEO vendor blogs with small samples. Google's own pages are marked (G). Claims I could not confirm are marked UNVERIFIED. Size: S = under an hour, M = a day, L = several days.

## Top 5

1. Bing Webmaster Tools + IndexNow (website). Cheap. Feeds Bing, and ChatGPT search is widely reported to read Bing.
2. Title and description rewrite, then measure in Search Console (website). Position 4 with 14 impressions means the page is seen but weak on clicks. Titles are the lever you fully control.
3. Forum answers on PowerForum, MyBroadband and the SunSynk SA Facebook group (Brynne). Owners with "app not updating" pain already ask there. Community threads are a named source for AI answers.
4. Directory listings: AlternativeTo, SaaSHub, StartupMap Africa (Brynne). Third-party pages supply most AI citations, not the product's own site.
5. Internal links from home to every new page, with plain anchor text (website). A new site with few backlinks relies on this for crawl and context.

## Website work (can be built in the repo)

Ordered by likely payoff.

### 1. Title and description rewrite
- What: write each page title (about 50-60 characters) and meta description around the exact words owners search. Put "SunSynk" and the task first, brand last.
- Size: S.
- Tradeoff: Google rewrites many titles anyway (one vendor claims about 76 percent). Titles do not lift rank by themselves. They change clicks.
- Source: https://developers.google.com/search/docs/appearance/title-link (G); https://developers.google.com/search/docs/appearance/snippet (G); https://ahrefs.com/blog/title-tags-study

### 2. Run a title test with Search Console
- What: change one title at a time. Keep the old text in git. In Performance, filter by Page, compare CTR at the same position over equal date ranges (28 days before and after). Use the Page + Query view for the exact query.
- Size: S to set up, 4-6 weeks wait.
- Tradeoff: at 14 impressions the data is noise. Wait for hundreds of impressions per page before judging. Do not change two things at once. Check for Search Console data gaps (a known loss on 23-24 Aug) before comparing.
- Source: https://support.google.com/webmasters/answer/7042828 (G, Performance report); https://blckalpaca.at/en/knowledge-base/seo-geo/on-page-seo/title-tags-2026-google-rewrites-76-how-to-prevent-it

### 3. Bing Webmaster Tools and IndexNow
- What: verify the site in Bing Webmaster Tools (it can import from Search Console). Submit the sitemap. Turn on IndexNow so Bing hears of new pages at once.
- Size: S.
- Tradeoff: Bing has a small share of search in South Africa. The payoff is mostly ChatGPT visibility. Several blogs say ChatGPT search uses Bing's index. An OpenAI help page only says "third-party providers", so this is not confirmed. Google does not use IndexNow.
- Source: https://www.bing.com/indexnow ; https://www.indexnow.org/documentation ; https://geo.tenten.co/en/blog/bing-webmaster-chatgpt-visibility (vendor, UNVERIFIED claim)

### 4. IndexNow on Cloudflare (Crawler Hints)
- What: Cloudflare dashboard, Caching, Configuration, Crawler Hints on. It pings IndexNow engines when content changes. For Pages, a build-step ping to the IndexNow endpoint with a key file in `public/` also works.
- Size: S.
- Tradeoff: Crawler Hints may not fire for a static site that rarely changes. One source warns the toggle can interact with robots settings, so recheck robots.txt after. Only helps Bing, Yandex, Naver, Seznam.
- Source: https://developers.cloudflare.com/cache/advanced-configuration/crawler-hints/ ; https://eseospace.com/blog/bing-webmaster-tools-indexnow-ai-search/

### 5. Internal links
- What: link home, footer and every help page to each comparison and alternative page. Use anchor text that says what the page is ("SunSynk app not updating"). Link help pages to each other and to sign-up.
- Size: S to M.
- Tradeoff: too many footer links dilute the signal. Link where it helps a reader.
- Source: https://developers.google.com/search/docs/fundamentals/seo-starter-guide (G, links section)

### 6. Sitemap hygiene and URL submission
- What: only indexable canonical URLs. Submit in Search Console and Bing. Use Request Indexing for each new page (about 10-15 a day).
- Size: S.
- Tradeoff: submitting does not force indexing. Internal links decide crawl speed. The sitemap itself is already planned; this is the submit and check routine.
- Source: https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap (G); https://ahrefs.com/blog/google-index/

### 7. Rich results that fit this site
- What: SoftwareApplication (planned) needs an aggregateRating or review for stars. Free plan: set offers.price to 0. Do not invent ratings. Add Organization markup (name, logo, url, sameAs). Add BreadcrumbList on help and compare pages. VideoObject if a video is embedded.
- Size: S to M.
- Tradeoff: FAQ rich results no longer appear in Google Search (reported as of 7 May 2026; limited to government and health sites since 2023). Keep FAQ markup only if cheap. Expect no extra clicks. HowTo is also cut back. Fake ratings risk a manual action.
- Source: https://developers.google.com/search/docs/appearance/structured-data/software-app (G); https://www.searchenginejournal.com/google-drops-faq-rich-results/574429/ ; https://developers.google.com/search/docs/appearance/structured-data/search-gallery (G, check current list)

### 8. Pages written for the question AI answers pick up
- What: short direct answer first (2-3 lines), then detail. Name the product, plan and price in plain text. One page per question. Add a "last updated" date. Name the company and the two people.
- Size: M.
- Tradeoff: no primary source says what AI Overviews use. Studies are vendor-run. One 2026 study found a product's own site gave only 12 percent of citations. Your own pages are needed but not enough.
- Source: https://www.datadab.com/research/how-saas-companies-get-cited ; https://gracker.ai/data-and-research-reports/how-to-get-cited-by-ai-10000-citations-study ; https://developers.google.com/search/docs/appearance/ai-features (G, AI features and your site)

### 9. Page speed and Core Web Vitals
- What: run PageSpeed Insights on home and the new pages. Targets: LCP 2.5 s or less, INP 200 ms or less, CLS 0.1 or less. Size images, defer scripts. The site compiles JSX with Babel into `public/build/`, so check bundle size on the showcase.
- Size: S to check, M if the showcase ships a large bundle.
- Tradeoff: Google staff call it a small factor. A claim that a March 2026 update tightened LCP to 2.0 s is UNVERIFIED. At 14 impressions speed is not the limit. Fix only real failures.
- Source: https://web.dev/articles/vitals (G); https://developers.google.com/search/docs/appearance/core-web-vitals (G); https://www.metadigital.co.nz/core-web-vitals-in-2026-what-they-measure-and-whats-actually-worth-fixing/

### 10. Brand-name search setup
- What: make "Prince Solar Hub" return the site first. Same name in title, Organization markup, logo and every profile (LinkedIn, Facebook, Hellopeter, directories). Add `sameAs` links. Check the name does not clash with other "Prince Solar" firms.
- Size: S.
- Tradeoff: only helps people who already know the name. Brand queries are a sign to watch in Search Console, not a way to find new users.
- Source: https://developers.google.com/search/docs/appearance/site-names (G); https://developers.google.com/search/docs/appearance/structured-data/organization (G)

### 11. .co.za and local signals
- What: .co.za is already a country signal. Add `lang="en-ZA"`, prices in R, South African examples (load-shedding, Eskom) in copy. Do not use hreflang unless a second language ships.
- Size: S.
- Tradeoff: little gain beyond what the domain gives. The .com redirect already passes the old name.
- Source: https://developers.google.com/search/docs/specialty/international/managing-multi-regional-sites (G); https://developers.google.com/search/docs/specialty/international/localized-versions (G)

### 12. Video on help pages
- What: a 30-60 second screen recording per help page ("restart the logger"). Embed the YouTube video. Add VideoObject markup and a text transcript.
- Size: M.
- Tradeoff: takes time to make. Video results for this niche in South African Google are untested. Statistics in the vendor sources are weak.
- Source: https://developers.google.com/search/docs/appearance/structured-data/video (G); https://www.ranktracker.com/blog/video-first-seo-embedding-youtube-boosts-rankings-2026

### 13. Search Console habits
- What: weekly: Page indexing report, Performance by Query, Links report (who links to you). URL Inspection live test after each deploy. Export Performance data monthly (Google keeps 16 months).
- Size: S, then 15 minutes a week.
- Tradeoff: little data now. The Links report shows whether a directory link counted.
- Source: https://support.google.com/webmasters/answer/9128668 (G, Links report); https://support.google.com/webmasters/answer/7042828 (G)

### 14. llms.txt
- What: a text file at /llms.txt listing key pages for AI tools.
- Size: S.
- Tradeoff: skip it. Google says it does not support it. Mueller compared it to the old keywords meta tag. Reported logs show AI bots almost never fetch it. Chrome Lighthouse has an experimental audit for it, the only pull. Ten minutes if wanted, no payoff expected.
- Source: https://www.techwyse.com/news/ai-search/google-john-mueller-llms-txt-speculative-webmcp-ai-agents ; https://www.optimizely.com/de/field-notes/articles/does-llms-txt-work (vendor blogs; the report that Google's May 2026 AI search guide lists it as "not needed" came from blogs, I did not open Google's page)

### 15. Invite rewards (in the product)
- What: "Invite a SunSynk owner, both get a month of Home". Share link in the app.
- Size: L (needs billing and abuse checks).
- Tradeoff: needs billing and abuse checks before it ships. Vendor sources rank value-led word of mouth above referral rewards. Own ticket if wanted.
- Source: https://productled.com/product-virality/ ; https://fungies.io/saas-referral-program-guide/

## Brynne's own outreach (she must do it herself)

Ordered by likely payoff. Nothing below should be posted or sent without Brynne.

### 1. PowerForum: SunSynk monitoring thread and "app not updating" threads
- What: answer real questions in the 28+ page "SunSynk - Inverter Monitoring" thread and nearby ones. Say she builds a monitor. Link only when it answers the question.
- Size: M (spread over weeks).
- Tradeoff: readers are technical and like SolarAssistant (a local Raspberry Pi tool). A hard sell gets removed. Read the forum's link and signature rules first. Threads are long and old, so replies may sit unread.
- Source: https://powerforum.co.za/topic/8451-sunsynk-inverter-monitoring/ ; https://powerforum.co.za/topic/34104-finding-and-understanding-the-sunsynk-operation-data/

### 2. MyBroadband forum ("All things Sunsynk", SolarAssistant threads)
- What: same method. Threads on monitoring SunSynk with SolarAssistant exist. A thread "Free SunSynk monitor, feedback wanted" fits only if the rules allow self-promo.
- Size: S per post.
- Tradeoff: large, general audience. Members dislike ads. Not confirmed here: the exact "All things Sunsynk" thread URL.
- Source: https://mybroadband.co.za/forum/threads/solarassistant-anyone-using-it.1170736/ ; https://mybroadband.co.za/forum/threads/monitoring-app-or-software-for-synapse-4-0-inverter.1195502/

### 3. SA solar Facebook groups (for example "Sunsynk South Africa")
- What: join, read, answer app problems for a few weeks, then share a help page when it fits.
- Size: M.
- Tradeoff: no search value (groups are not indexed). Strong reach to the exact owners. Admins ban link drops. A 4x4 Community post confirms a SunSynk SA Facebook group exists. Member count and rules not checked.
- Source: https://www.4x4community.co.za/forum/showthread.php/378204-Inverter-Temperature

### 4. AlternativeTo, SaaSHub, StartupMap Africa
- What: list the product and name SunSynk Connect, Solarman and SolarAssistant as the alternatives. StartupMap Africa has a free form, reviewed in a few days.
- Size: S each.
- Tradeoff: dofollow or nofollow differs by site and sources conflict, so view source on the live listing. AlternativeTo value is "alternative to" intent and AI citations.
- Source: https://startupmapafrica.com/submit ; https://ideaproof.io/launch-directories/saashub ; https://saascity.io/blog/free-saas-directories-backlinks-2026

### 5. Installer backlinks
- What: ask 5-10 SunSynk installers to link the help pages from their after-install page or handover email. Offer a free tool for their customers.
- Size: M.
- Tradeoff: strongest link type for a local site, slowest to land. Installers may see monitoring as their own add-on. Ask for a link only, never a settings change (project rule).
- Source: https://developers.google.com/search/docs/essentials/spam-policies#link-spam (G: no paid or traded links, ask for editorial links only)

### 6. Press: MyBroadband, TechCentral, Daily Maverick, Ventureburn, local radio
- What: one short pitch with a news hook: father and daughter build a free SunSynk monitor for the load-shedding era. One real number (with permission) and a demo link. Radio: regional consumer-tech and energy slots.
- Size: M.
- Tradeoff: low reply rate, no control of timing. One article gives a high-trust link and a name AI tools can cite. I found no Ventureburn or TechCentral submission pages, so use their contact pages. I found no MyBroadband article on a comparable app.
- Source: https://www.engineeringnews.co.za/article/solar-users-should-focus-on-monitoring-managing-and-maximising-assets-2025-07-18 (shows the media angle exists); https://blog.mean.ceo/startups-south-africa-news-august-2026/ (who covers SA startups)

### 7. Reddit (r/southafrica, r/solar, r/homeassistant)
- What: answer questions about SunSynk monitoring. Disclose. Read each sub's self-promo rule first.
- Size: S per post.
- Tradeoff: threads are said to feed AI answers, but only vendor studies say so. A 9:1 helpful-to-promo ratio is a norm, not a Reddit rule. A new account posting a link gets removed.
- Source: https://redship.io/blog/reddit-self-promotion-rules-2026 (vendor, UNVERIFIED on exact rules)

### 8. Product Hunt launch
- What: one launch day with a short demo and a first comment.
- Size: M.
- Tradeoff: SA solar owners are not there. The link is mostly nofollow. Value is a high-authority listing page and AI mentions. Launch after the compare pages are live. One shot only.
- Source: https://trustroi.beehiiv.com/p/product-hunt-alternatives-2026-best-platforms-indie-saas (vendor)

### 9. Hellopeter and Trustpilot
- What: claim the free Hellopeter profile. Ask happy users for a review.
- Size: S.
- Tradeoff: claiming is free. Replying to reviews and review invites are paid. Hellopeter is a complaints site, so an empty profile looks odd. Hellopeter says Google's AI cites it (its own claim). Trustpilot reach in South Africa not checked.
- Source: https://biz.hellopeter.com/blogs/post/intro-to-hellopeter-business-how-it-helps-south-african-businesses-grow1

### 10. Real ratings for SoftwareApplication stars
- What: collect 5+ honest reviews on one third-party site, then mark up only ratings that show on the page.
- Size: M.
- Tradeoff: no stars until real reviews exist. Fake or self-written ratings break Google's policy.
- Source: https://developers.google.com/search/docs/appearance/structured-data/review-snippet (G)

### 11. G2 and Capterra
- What: free listing for software. Reviews need real users.
- Size: M.
- Tradeoff: built for B2B buyers, US and EU traffic. SE Ranking found review sites gave 8.5 percent of AI Overview links. Low payoff for a home-owner app. One vendor says G2 gets a product "in the room" for AI answers.
- Source: https://dupple.com/learn/best-saas-directories-2026 ; https://www.datadab.com/research/how-saas-companies-get-cited

### 12. Google Business Profile
- What: Google says an online-only business with no customer visits is not eligible. A profile is allowed if you meet customers in person or travel to them, and the address must be real. P.O. boxes and virtual offices are rejected.
- Size: S to check, M to verify.
- Tradeoff: skip unless the company has a real office where customers are met. A faked profile risks suspension. A profile would not show for "SunSynk monitoring" anyway.
- Source: https://support.google.com/business/answer/7039811 (G); https://www.brightlocal.com/learn/google-business-profile/getting-started/service-area-businesses/

### 13. YouTube channel
- What: put each help video on a channel as well as the page. Title = the owner's question. Help page link in the description.
- Size: M.
- Tradeoff: slow to build. YouTube links are nofollow. Reach is YouTube search and Google video results, for SunSynk owners worldwide, not only SA.
- Source: https://www.ranktracker.com/blog/video-first-seo-embedding-youtube-boosts-rankings-2026 (vendor)

### 14. SA startup lists and awards
- What: Platform ZA (Startup Club ZA), South African Startup Awards (ceremony 18 Nov 2026, entries probably closed), MEAN CEO monthly SA startup roundup.
- Size: S.
- Tradeoff: reaches founders and investors, not solar owners. Small link value, but real local indexed pages.
- Source: https://www.bizcommunity.com/article/startup-club-za-launches-platform-za-to-tackle-access-gaps-in-sas-tech-ecosystem-739622a ; https://innovation-village.com/entries-open-for-the-2026-south-african-startup-awards-celebrating-emerging-tech-innovation/

### 15. Ask current users to tell one SunSynk owner each
- What: ask current users and the testers.
- Size: S.
- Tradeoff: helps the product, not search. Fits before any reward scheme.
- Source: https://productled.com/product-virality/

## Open gaps (not verified in this pass)

- Whether ChatGPT search reads Bing's index. Blogs say yes. OpenAI's own wording does not name Bing.
- Dofollow status of each directory. Check on the live listing.
- Google's own AI search guide (May 2026) and its llms.txt line. Seen only via blogs.
- Trustpilot reach in South Africa. PowerForum and MyBroadband self-promo rules.
- Product Hunt traffic for SA solar owners.
- Several Google doc URLs marked (G) are from memory of Search Central's layout, not opened. Only the SoftwareApplication and Business Profile pages appeared in search results.
