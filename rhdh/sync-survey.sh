#!/usr/bin/env bash
# sync-survey.sh — traz o survey do job template do AAP para dentro do portal.
#
# O survey e a FONTE DA VERDADE: quem manda no formulario e o AAP, e este
# script regenera o software template do RHDH a partir dele. Mudou uma pergunta
# no AAP, roda isto e o portal acompanha -- em vez de manter dois formularios
# parecidos que divergem na primeira alteracao.
#
# O template gerado nao clona repositorio nem escreve arquivo: ele so dispara o
# job pela API do controller, atraves do proxy do RHDH (endpoint /aap, definido
# no rhdh/setup-plugins.sh). Por isso a entidade sai em rhdh/catalog/ e e
# servida pelo httpd interno, junto com o resto do catalogo -- nao ha skeleton
# para hospedar no git, e assim o sync nao depende de push.
#
# Uso:
#   bash rhdh/sync-survey.sh
#   JT_NAME='Outro job template' bash rhdh/sync-survey.sh
#   SKIP_PUBLISH=true bash rhdh/sync-survey.sh   # so regenera o arquivo
#
# Pre-requisitos: oc (autenticado), curl, python3, e o job template ja criado
# (aap/setup-job-template.sh).

set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${_here}/lib.sh" || { echo "rhdh/lib.sh ausente" >&2; exit 1; }

_need oc curl python3
_need_cluster

RHDH_NS="${RHDH_NS:-$(_discover_rhdh_ns)}"

AAP_URL="${RHAAP_BASE_URL:-$(oc get secret rhdh-ansible-secret -n "$RHDH_NS" \
  -o jsonpath='{.data.RHAAP_BASE_URL}' 2>/dev/null | base64 -d)}"
AAP_TOKEN="${RHAAP_TOKEN:-$(oc get secret rhdh-ansible-secret -n "$RHDH_NS" \
  -o jsonpath='{.data.RHAAP_TOKEN}' 2>/dev/null | base64 -d)}"
[[ -n "$AAP_URL" && -n "$AAP_TOKEN" ]] \
  || _die "sem RHAAP_BASE_URL/RHAAP_TOKEN: rode a camada Ansible do rhdh/ antes, ou exporte as duas."

_api() {
  curl -sk --max-time 60 -H "Authorization: Bearer ${AAP_TOKEN}" \
    "${AAP_URL}/api/controller/v2/$1"
}

JT_NAME="${JT_NAME:-Smoke test do parceiro}"
_log "procurando o job template '${JT_NAME}'..."
JT_ID="$(_api "job_templates/?name=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$JT_NAME")" \
  | python3 -c "
import json,sys
try: r=(json.load(sys.stdin).get('results') or [])
except Exception: r=[]
print(r[0]['id'] if r else '')
" 2>/dev/null)"
[[ -n "$JT_ID" ]] || _die "job template '${JT_NAME}' nao existe no AAP; rode aap/setup-job-template.sh antes."
_ok "job template id ${JT_ID}."

_survey_json="$(_api "job_templates/${JT_ID}/survey_spec/")"
# survey_enabled desligado devolve um spec vazio, nao um erro: gerar em cima
# disso produziria um template sem nenhum campo, que abre e nao pergunta nada.
_nq="$(printf '%s' "$_survey_json" | python3 -c "
import json,sys
try: print(len(json.load(sys.stdin).get('spec') or []))
except Exception: print(0)
" 2>/dev/null)"
[[ "${_nq:-0}" -gt 0 ]] || _die "o job template ${JT_ID} nao tem survey (ou esta desabilitado)."
_log "survey com ${_nq} pergunta(s)."

_out="${_here}/catalog/aap-smoke-test.yaml"

# ---------------------------------------------------------------------------
# O gerador. Um mapa de tipo do AAP -> JSON Schema do scaffolder:
#
#   text/textarea   string          (min/max do AAP sao COMPRIMENTO)
#   password        string + Secret (fica em ctx.secrets, fora do registro da
#                                    tarefa -- chave de API nao pode ir parar
#                                    no historico do scaffolder)
#   integer/float   integer/number  (min/max sao VALOR -- confundir os dois
#                                    gera um schema que recusa toda entrada)
#   multiplechoice  string + enum
#   multiselect     array de string + enum nos items
# ---------------------------------------------------------------------------
python3 - "$_survey_json" "$JT_ID" "$JT_NAME" "$AAP_URL" > "$_out" <<'PY' || _die "falha ao gerar o template."
import json, sys

survey = json.loads(sys.argv[1])
jt_id, jt_name, aap_url = sys.argv[2], sys.argv[3], sys.argv[4].rstrip('/')

def choices(q):
    c = q.get('choices') or []
    # Versoes diferentes do controller devolvem lista ou string com quebras de
    # linha. Tratar so uma das duas deixa o enum vazio, e o campo vira um
    # select sem opcao nenhuma.
    if isinstance(c, str):
        c = [x for x in (l.strip() for l in c.splitlines()) if x]
    return c

props, required, secrets = {}, [], []
for q in survey.get('spec') or []:
    var, t = q['variable'], q.get('type', 'text')
    p = {'title': q.get('question_name') or var}
    if q.get('question_description'):
        p['description'] = q['question_description']

    if t in ('text', 'textarea', 'password'):
        p['type'] = 'string'
        if q.get('min') not in (None, ''): p['minLength'] = int(q['min'])
        if q.get('max') not in (None, ''): p['maxLength'] = int(q['max'])
        if t == 'textarea':
            p['ui:widget'] = 'textarea'
        if t == 'password':
            p['ui:field'] = 'Secret'
            secrets.append(var)
    elif t in ('integer', 'float'):
        p['type'] = 'integer' if t == 'integer' else 'number'
        if q.get('min') not in (None, ''): p['minimum'] = q['min']
        if q.get('max') not in (None, ''): p['maximum'] = q['max']
    elif t == 'multiplechoice':
        p['type'] = 'string'
        p['enum'] = choices(q)
    elif t == 'multiselect':
        p['type'] = 'array'
        p['items'] = {'type': 'string', 'enum': choices(q)}
        p['uniqueItems'] = True
    else:
        p['type'] = 'string'

    # Default de campo Secret nao vai: o valor nao volta pelo formulario e um
    # default aqui daria a impressao de que o campo ja esta preenchido.
    d = q.get('default')
    if d not in (None, '') and var not in secrets:
        p['default'] = d
    if q.get('required'):
        required.append(var)

    props[var] = p

def ref(var):
    return '${{ secrets.%s }}' % var if var in secrets else '${{ parameters.%s }}' % var

entity = {
    'apiVersion': 'scaffolder.backstage.io/v1beta3',
    'kind': 'Template',
    'metadata': {
        'name': 'aap-smoke-test',
        'title': jt_name,
        'description': survey.get('description')
            or 'Dispara o job template do AAP a partir do portal.',
        'tags': ['ansible', 'aap', 'rhcl'],
        # Vocabulario de docs/CATALOGO.md, conferido pelo
        # scripts/valida-catalogo.sh. 'origem: repo' porque a entidade nasce
        # deste repositorio -- o survey vem do AAP, mas quem a escreve e este
        # script. Sem 'camada': Template e organizacional, nao arquitetural.
        #
        # Precisa estar AQUI e nao no arquivo gerado: o proximo sync
        # sobrescreve rhdh/catalog/aap-smoke-test.yaml inteiro.
        'labels': {
            'rhcl.demo/origem': 'repo',
        },
        'annotations': {
            # De onde este arquivo veio. Editar a mao nao adianta: o proximo
            # sync sobrescreve.
            'rhcl.demo/gerado-por': 'rhdh/sync-survey.sh',
            'rhcl.demo/aap-job-template': str(jt_id),
        },
    },
    'spec': {
        'owner': 'group:default/platform-team',
        'type': 'automation',
        'parameters': [{
            'title': survey.get('name') or jt_name,
            'description': 'Os campos abaixo sao o survey do job template '
                           '%s no AAP, sincronizados por rhdh/sync-survey.sh.' % jt_id,
            'required': required,
            'properties': props,
        }],
        'steps': [{
            'id': 'launch',
            'name': 'Disparar o job no AAP',
            'action': 'http:backstage:request',
            'input': {
                'method': 'POST',
                # Caminho do proxy do RHDH, nao a URL do AAP: e o proxy que
                # injeta o token e aceita o certificado do cluster. Com a URL
                # direta o backend teria de carregar credencial.
                #
                # SEM o prefixo '/api'. A acao trata o PRIMEIRO segmento do
                # path como plugin id e resolve a base por discovery: com
                # '/api/proxy/...' o plugin vira 'api', a base sai
                # 'http://localhost:7007/api/api' e o POST bate em
                # /api/api/proxy/... -- 404 com corpo vazio, que nao parece
                # erro de caminho nenhum.
                'path': '/proxy/aap/api/controller/v2/job_templates/%s/launch/' % jt_id,
                'headers': {'content-type': 'application/json'},
                'body': {'extra_vars': {v: ref(v) for v in props}},
            },
        }],
        'output': {
            'links': [{
                'title': 'Acompanhar o job no AAP',
                'url': aap_url + '/execution/jobs/playbook/${{ steps.launch.output.body.id }}/output',
            }],
            'text': [{
                'title': 'Job disparado',
                'content': 'Job **${{ steps.launch.output.body.id }}** '
                           'do template *%s* (id %s).' % (jt_name, jt_id),
            }],
        },
    },
}

print('# GERADO POR rhdh/sync-survey.sh -- NAO EDITE A MAO.')
print('# Fonte: survey do job template %s ("%s") em %s' % (jt_id, jt_name, aap_url))
print('# Para mudar o formulario, mude o survey no AAP e rode o sync de novo.')
print('---')

# json.dump em vez de yaml.dump de proposito: YAML e superconjunto de JSON, o
# catalogo aceita, e o repo nao passa a depender de PyYAML instalado na
# maquina de quem roda a demo.
print(json.dumps(entity, indent=2, ensure_ascii=False))
PY

_ok "template gerado em rhdh/catalog/aap-smoke-test.yaml"
python3 -c "
import json,sys
raw=open(sys.argv[1]).read()
d=json.loads(raw.split('---',1)[1])
p=d['spec']['parameters'][0]
print('  campos:', ', '.join(p['properties']))
print('  obrigatorios:', ', '.join(p['required']) or '(nenhum)')
" "$_out"

if [[ "${SKIP_PUBLISH:-false}" == "true" ]]; then
  _log "SKIP_PUBLISH=true -- nao publiquei no portal."
  exit 0
fi

_log "publicando o catalogo..."
bash "${_here}/setup-catalog.sh" || _die "falha ao publicar o catalogo."
_ok "sincronizado. O template aparece em Create como '${JT_NAME}'."
