# Dashboard — Funil de Tráfego (Meta Ads)

Dashboard que cruza **3 planilhas** (Queries do Meta × Lista de leads × Vendas) e monta o funil completo, atualizando sozinha a cada 3h, 100% na nuvem.

- `build.ps1` baixa as 3 planilhas (CSV `gviz`), aplica imposto **×1,1385** e gera `data.js`.
- `index.html` + `app.js` + `styles.css`: página estática (cache-bust, sem libs).
- **Atualização 3h:** GitHub Actions roda o build e publica no GitHub Pages; disparado pelo **cron-job.org** a cada 3h.

Métricas (com imposto): Investimento, CPM, CTR, CPC, CPV, CPL, CAC, ROAS. Atribuição de leads/vendas por campanha/conjunto/anúncio. Somente leitura — nada é alterado nas planilhas.
