const webhookData = $('webhook-report').item.json;
const body = webhookData.body || webhookData;

const tipo = body.tipo || 'mensal';
const label = body.label || '';
const startPeriod = body.startDate || '';
const endPeriod = body.endDate || '';

const itemsSrc = $items('buscar-gastos');

function round2(n) {
  const x = Number(n ?? 0);
  return Number.isFinite(x) ? Number(x.toFixed(2)) : 0;
}

function dISO(s) {
  if (!s) return '';
  const d = new Date(s);
  if (isNaN(d)) return '';
  const dia = String(d.getDate()).padStart(2, '0');
  const mes = String(d.getMonth() + 1).padStart(2, '0');
  const ano = d.getFullYear();
  return `${dia}/${mes}/${ano}`;
}

function formatDateShortISO(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (isNaN(d)) return '';
  const dia = String(d.getDate()).padStart(2, '0');
  const mes = String(d.getMonth() + 1).padStart(2, '0');
  const ano = d.getFullYear();
  return `${dia}/${mes}/${ano}`;
}

let labelSaidas = 'Total de saídas:';
let labelEntradas = 'Total de entradas:';
let labelSaldo = 'Saldo:';

if (tipo === 'semanal') {
  labelSaidas = 'Saídas na semana:';
  labelEntradas = 'Entradas na semana:';
  labelSaldo = 'Saldo da semana:';
}

let periodoDatas = '';
if (startPeriod && endPeriod) {
  const inicio = formatDateShortISO(startPeriod);
  const fim = formatDateShortISO(endPeriod);
  if (inicio && fim) {
    periodoDatas = `${inicio} a ${fim}`;
  }
}

const regs = itemsSrc.map(it => ({
  Data: dISO(it.json.date_spent),
  Nome: it.json.name_spent ?? '',
  Categoria: it.json.category_spent ?? 'Outros',
  Transacao: String(it.json.transaction_type || '').toLowerCase(),
  Valor: round2(it.json.value_spent)
})).filter(r => !!r.Data);

const saidas = regs.filter(r => r.Transacao === 'saida');
const entradas = regs.filter(r => r.Transacao === 'entrada');

const totalSaidas = round2(saidas.reduce((s, r) => s + (r.Valor || 0), 0));
const totalEntradas = round2(entradas.reduce((s, r) => s + (r.Valor || 0), 0));
const saldoFinal = round2(totalEntradas - totalSaidas);

// ========================================
// AGRUPAR SAÍDAS POR CATEGORIA
// ========================================
const categoriasSaidas = {};
for (const r of saidas) {
  if (!categoriasSaidas[r.Categoria]) {
    categoriasSaidas[r.Categoria] = [];
  }
  categoriasSaidas[r.Categoria].push(r);
}

// Ordenar categorias por total (maior gasto primeiro)
const categoriasOrdenadas = Object.entries(categoriasSaidas)
  .map(([cat, items]) => ({
    nome: cat,
    items: items.sort((a, b) => b.Valor - a.Valor),
    total: round2(items.reduce((s, r) => s + r.Valor, 0))
  }))
  .sort((a, b) => b.total - a.total);

// ========================================
// AGRUPAR ENTRADAS POR CATEGORIA
// ========================================
const categoriasEntradas = {};
for (const r of entradas) {
  if (!categoriasEntradas[r.Categoria]) {
    categoriasEntradas[r.Categoria] = [];
  }
  categoriasEntradas[r.Categoria].push(r);
}

const entradasOrdenadas = Object.entries(categoriasEntradas)
  .map(([cat, items]) => ({
    nome: cat,
    items: items.sort((a, b) => b.Valor - a.Valor),
    total: round2(items.reduce((s, r) => s + r.Valor, 0))
  }))
  .sort((a, b) => b.total - a.total);

// ========================================
// CORES POR CATEGORIA
// ========================================
const coresCategorias = {
  'Alimentacao': '#FF6B6B',
  'Mercado': '#4ECDC4',
  'Moradia': '#45B7D1',
  'Transporte': '#96CEB4',
  'Saude': '#FFEAA7',
  'Educacao': '#DDA0DD',
  'Vestuario': '#98D8C8',
  'Investimentos': '#F7DC6F',
  'Lazer': '#BB8FCE',
  'Tecnologia': '#85C1E9',
  'Outros': '#AEB6BF'
};

function corCategoria(cat) {
  return coresCategorias[cat] || '#AEB6BF';
}

// ========================================
// GERAR BARRA DE PROPORÇÃO (visual por categoria)
// ========================================
function gerarBarraProporcao() {
  if (categoriasOrdenadas.length === 0) return '';

  const barras = categoriasOrdenadas.map(c => {
    const pct = totalSaidas > 0 ? ((c.total / totalSaidas) * 100).toFixed(1) : 0;
    return `<div style="width:${pct}%;background:${corCategoria(c.nome)};height:24px;display:inline-block;" title="${c.nome}: ${pct}%"></div>`;
  }).join('');

  const legenda = categoriasOrdenadas.map(c => {
    const pct = totalSaidas > 0 ? ((c.total / totalSaidas) * 100).toFixed(0) : 0;
    return `<span style="font-size:10px;color:#666;margin-right:12px;"><span style="display:inline-block;width:10px;height:10px;background:${corCategoria(c.nome)};border-radius:2px;margin-right:3px;vertical-align:middle;"></span>${c.nome} ${pct}%</span>`;
  }).join('');

  return `
    <div style="margin:20px 0 8px 0;">
      <div style="font-size:11px;color:#888;text-transform:uppercase;letter-spacing:0.5px;margin-bottom:6px;">Distribuição por categoria</div>
      <div style="width:100%;border-radius:6px;overflow:hidden;display:flex;">${barras}</div>
      <div style="margin-top:6px;">${legenda}</div>
    </div>
  `;
}

// ========================================
// GERAR SEÇÃO DE CATEGORIA
// ========================================
function gerarSecaoCategoria(cat, tipo) {
  const cor = tipo === 'saida' ? '#fff5f5' : '#f3faf3';
  const corBorda = corCategoria(cat.nome);

  const linhas = cat.items.map(r => `
    <tr style="background:${cor};">
      <td style="padding:6px 8px;border-bottom:1px solid #f0f0f0;">${r.Data}</td>
      <td style="padding:6px 8px;border-bottom:1px solid #f0f0f0;">${r.Nome}</td>
      <td style="padding:6px 8px;border-bottom:1px solid #f0f0f0;text-align:right;">R$ ${r.Valor.toFixed(2).replace('.', ',')}</td>
    </tr>
  `).join('');

  return `
    <div style="margin-bottom:20px;">
      <div style="display:flex;align-items:center;margin-bottom:8px;">
        <div style="width:4px;height:20px;background:${corBorda};border-radius:2px;margin-right:8px;"></div>
        <span style="font-size:14px;font-weight:600;color:#333;">${cat.nome}</span>
        <span style="margin-left:auto;font-size:14px;font-weight:700;color:#333;">R$ ${cat.total.toFixed(2).replace('.', ',')}</span>
      </div>
      <table style="width:100%;border-collapse:collapse;font-size:12px;">
        <thead>
          <tr>
            <th style="text-align:left;padding:6px 8px;border-bottom:1px solid #ddd;font-size:10px;text-transform:uppercase;color:#999;">Data</th>
            <th style="text-align:left;padding:6px 8px;border-bottom:1px solid #ddd;font-size:10px;text-transform:uppercase;color:#999;">Nome</th>
            <th style="text-align:right;padding:6px 8px;border-bottom:1px solid #ddd;font-size:10px;text-transform:uppercase;color:#999;">Valor</th>
          </tr>
        </thead>
        <tbody>
          ${linhas}
        </tbody>
      </table>
    </div>
  `;
}

// ========================================
// MONTAR HTML
// ========================================
const logoUrl = 'https://totalassistente.com.br/assets/logo-dark-DnpWvJkw.png';

const secoesSaidas = categoriasOrdenadas.map(c => gerarSecaoCategoria(c, 'saida')).join('');
const secoesEntradas = entradasOrdenadas.map(c => gerarSecaoCategoria(c, 'entrada')).join('');

const html = `
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8" />
<title>Relatório - Total Assistente</title>
<style>
  body {
    font-family: Arial, sans-serif;
    margin: 32px;
    color: #333;
  }
  .header {
    display: flex;
    align-items: center;
    margin-bottom: 32px;
  }
  .header img {
    height: 40px;
  }
  .periodo {
    text-align: left;
    font-size: 22px;
    font-weight: 700;
    color: #111;
    margin-bottom: 4px;
  }
  .periodo-datas {
    font-size: 13px;
    color: #888;
    margin-bottom: 28px;
  }
  .secao-titulo {
    font-size: 16px;
    font-weight: 700;
    color: #222;
    margin: 28px 0 16px 0;
    padding-bottom: 8px;
    border-bottom: 2px solid #222;
  }
  .totais {
    margin-top: 28px;
    font-size: 14px;
  }
  .totais .linha {
    display: flex;
    justify-content: space-between;
    padding: 6px 0;
    border-bottom: 1px solid #f0f0f0;
  }
  .totais .linha:last-child {
    border-bottom: none;
    padding-top: 10px;
    font-size: 16px;
  }
  .positivo {
    color: #0a7a00;
    font-weight: 700;
  }
  .negativo {
    color: #c00;
    font-weight: 700;
  }
  .footer {
    margin-top: 40px;
    font-size: 10px;
    text-align: center;
    color: #aaa;
  }
</style>
</head>
<body>
  <div class="header">
    <img src="${logoUrl}" alt="Total Assistente" />
  </div>

  <div class="periodo">${label || 'Relatório'}</div>
  <div class="periodo-datas">${periodoDatas}</div>

  ${gerarBarraProporcao()}

  ${categoriasOrdenadas.length > 0 ? `
    <div class="secao-titulo">Saídas por Categoria</div>
    ${secoesSaidas}
  ` : ''}

  ${entradasOrdenadas.length > 0 ? `
    <div class="secao-titulo">Entradas por Categoria</div>
    ${secoesEntradas}
  ` : ''}

  ${categoriasOrdenadas.length === 0 && entradasOrdenadas.length === 0 ? `
    <div style="text-align:center;color:#aaa;padding:40px;font-size:14px;">Nenhum lançamento no período.</div>
  ` : ''}

  <div class="totais">
    <div class="linha">
      <span>${labelSaidas}</span>
      <span>R$ ${totalSaidas.toFixed(2).replace('.', ',')}</span>
    </div>
    <div class="linha">
      <span>${labelEntradas}</span>
      <span>R$ ${totalEntradas.toFixed(2).replace('.', ',')}</span>
    </div>
    <div class="linha">
      <span>${labelSaldo}</span>
      <span class="${saldoFinal >= 0 ? 'positivo' : 'negativo'}">
        R$ ${saldoFinal.toFixed(2).replace('.', ',')}
      </span>
    </div>
  </div>

  <div class="footer">
    Total Assistente
  </div>
</body>
</html>
`;

return [{
  json: {
    html
  }
}];
