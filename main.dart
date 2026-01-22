import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:csv/csv.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_tts/flutter_tts.dart';

void main() {
  runApp(const DiccionarioApp());
}

enum Lang { es, en, de, fr }

String langLabel(Lang l) {
  switch (l) {
    case Lang.es: return 'Español';
    case Lang.en: return 'English';
    case Lang.de: return 'Deutsch';
    case Lang.fr: return 'Français';
  }
}

String langCode(Lang l) {
  // Android TTS usa códigos tipo "es-ES", "en-US", etc.
  switch (l) {
    case Lang.es: return 'es-ES';
    case Lang.en: return 'en-US';
    case Lang.de: return 'de-DE';
    case Lang.fr: return 'fr-FR';
  }
}

class Term {
  final String id;
  final String category;
  final String es;
  final String en;
  final String de;
  final String fr;
  final String synonymsEs;
  final String notes;

  const Term({
    required this.id,
    required this.category,
    required this.es,
    required this.en,
    required this.de,
    required this.fr,
    required this.synonymsEs,
    required this.notes,
  });

  String valueFor(Lang l) {
    switch (l) {
      case Lang.es: return es;
      case Lang.en: return en;
      case Lang.de: return de;
      case Lang.fr: return fr;
    }
  }

  static Term fromMap(Map<String, Object?> m) => Term(
    id: (m['id'] ?? '').toString(),
    category: (m['category'] ?? '').toString(),
    es: (m['es'] ?? '').toString(),
    en: (m['en'] ?? '').toString(),
    de: (m['de'] ?? '').toString(),
    fr: (m['fr'] ?? '').toString(),
    synonymsEs: (m['synonyms_es'] ?? '').toString(),
    notes: (m['notes'] ?? '').toString(),
  );
}

class AppDb {
  static const _dbName = 'diccionario.db';
  static const _dbVersion = 1;

  Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    final path = p.join(await getDatabasesPath(), _dbName);
    _db = await openDatabase(
      path,
      version: _dbVersion,
      onCreate: (d, v) async {
        await d.execute('''
          CREATE TABLE terms(
            id TEXT PRIMARY KEY,
            category TEXT,
            es TEXT,
            en TEXT,
            de TEXT,
            fr TEXT,
            synonyms_es TEXT,
            notes TEXT
          );
        ''');
        await d.execute('''
          CREATE TABLE favorites(
            id TEXT PRIMARY KEY
          );
        ''');
        await d.execute('''
          CREATE TABLE history(
            q TEXT NOT NULL,
            ts INTEGER NOT NULL
          );
        ''');
        await d.execute('CREATE INDEX idx_terms_es ON terms(es);');
        await d.execute('CREATE INDEX idx_terms_en ON terms(en);');
        await d.execute('CREATE INDEX idx_terms_de ON terms(de);');
        await d.execute('CREATE INDEX idx_terms_fr ON terms(fr);');
        await d.execute('CREATE INDEX idx_terms_cat ON terms(category);');
        await d.execute('CREATE INDEX idx_history_ts ON history(ts);');
      },
    );
    return _db!;
  }

  Future<bool> hasTerms() async {
    final d = await db;
    final r = await d.rawQuery('SELECT COUNT(*) as c FROM terms');
    final c = (r.first['c'] as int?) ?? 0;
    return c > 0;
  }

  Future<void> importFromCsvAssetIfEmpty() async {
    if (await hasTerms()) return;

    final csvText = await rootBundle.loadString('assets/diccionario.csv');
    final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false).convert(csvText);
    if (rows.length <= 1) return;

    final header = rows.first.map((e) => e.toString()).toList();
    int idx(String col) => header.indexOf(col);

    final d = await db;
    await d.transaction((txn) async {
      final batch = txn.batch();
      for (int i = 1; i < rows.length; i++) {
        final r = rows[i].map((e) => e.toString()).toList();
        if (r.isEmpty) continue;

        String at(int j) => (j >= 0 && j < r.length) ? r[j].trim() : '';
        final id = at(idx('id'));
        if (id.isEmpty) continue;

        batch.insert('terms', {
          'id': id,
          'category': at(idx('Categoría')),
          'es': at(idx('Español')),
          'en': at(idx('English')),
          'de': at(idx('Deutsch')),
          'fr': at(idx('Français')),
          'synonyms_es': at(idx('Sinónimos (ES)')),
          'notes': at(idx('Notas')),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<String>> categories() async {
    final d = await db;
    final rows = await d.rawQuery('SELECT DISTINCT category FROM terms WHERE category != "" ORDER BY category COLLATE NOCASE');
    final cats = rows.map((e) => (e['category'] ?? '').toString()).where((e) => e.isNotEmpty).toList();
    return ['Todas', ...cats];
  }

  Future<void> addHistory(String q) async {
    final qq = q.trim();
    if (qq.isEmpty) return;
    final d = await db;
    await d.insert('history', {'q': qq, 'ts': DateTime.now().millisecondsSinceEpoch});
    // Mantener historial acotado
    await d.execute('''
      DELETE FROM history
      WHERE rowid NOT IN (
        SELECT rowid FROM history ORDER BY ts DESC LIMIT 100
      );
    ''');
  }

  Future<List<String>> getHistory() async {
    final d = await db;
    final rows = await d.rawQuery('SELECT q FROM history ORDER BY ts DESC LIMIT 50');
    return rows.map((e) => (e['q'] ?? '').toString()).where((e) => e.isNotEmpty).toList();
  }

  Future<void> clearHistory() async {
    final d = await db;
    await d.delete('history');
  }

  Future<Set<String>> favoriteIds() async {
    final d = await db;
    final rows = await d.query('favorites');
    return rows.map((e) => (e['id'] ?? '').toString()).toSet();
  }

  Future<bool> isFavorite(String id) async {
    final d = await db;
    final rows = await d.query('favorites', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isNotEmpty;
  }

  Future<void> setFavorite(String id, bool fav) async {
    final d = await db;
    if (fav) {
      await d.insert('favorites', {'id': id}, conflictAlgorithm: ConflictAlgorithm.replace);
    } else {
      await d.delete('favorites', where: 'id = ?', whereArgs: [id]);
    }
  }

  Future<List<Term>> getFavorites() async {
    final d = await db;
    final rows = await d.rawQuery('''
      SELECT t.* FROM terms t
      INNER JOIN favorites f ON f.id = t.id
      ORDER BY t.es COLLATE NOCASE
    ''');
    return rows.map(Term.fromMap).toList();
  }

  Future<List<Term>> search({
    required String query,
    required Lang from,
    required String categoryFilter,
    required bool onlyFavorites,
    int limit = 200,
  }) async {
    final d = await db;
    final q = query.trim().toLowerCase();
    final fromCol = switch (from) {
      Lang.es => 'es',
      Lang.en => 'en',
      Lang.de => 'de',
      Lang.fr => 'fr',
    };

    final where = <String>[];
    final args = <Object?>[];

    if (categoryFilter != 'Todas') {
      where.add('category = ?');
      args.add(categoryFilter);
    }

    if (onlyFavorites) {
      where.add('id IN (SELECT id FROM favorites)');
    }

    if (q.isNotEmpty) {
      // Buscar en el idioma origen + permitir búsqueda global + sinónimos ES
      where.add('('
          'LOWER($fromCol) LIKE ? OR '
          'LOWER(es) LIKE ? OR LOWER(en) LIKE ? OR LOWER(de) LIKE ? OR LOWER(fr) LIKE ? OR '
          'LOWER(synonyms_es) LIKE ? OR LOWER(category) LIKE ?'
          ')');
      final like = '%$q%';
      args.addAll([like, like, like, like, like, like, like]);
    }

    final whereSql = where.isEmpty ? '' : 'WHERE ' + where.join(' AND ');
    final rows = await d.rawQuery('''
      SELECT * FROM terms
      $whereSql
      ORDER BY es COLLATE NOCASE
      LIMIT $limit
    ''', args);

    return rows.map(Term.fromMap).toList();
  }
}

class DiccionarioApp extends StatelessWidget {
  const DiccionarioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Diccionario Culinario',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _db = AppDb();
  final _tts = FlutterTts();

  final TextEditingController _q = TextEditingController();
  bool _loading = true;

  Lang _from = Lang.es;
  Lang _to = Lang.en;

  String _category = 'Todas';
  bool _onlyFavorites = false;

  List<String> _categories = const ['Todas'];
  List<Term> _results = const [];
  Set<String> _favIds = {};

  @override
  void initState() {
    super.initState();
    _init();
    _q.addListener(_applyFilters);
  }

  @override
  void dispose() {
    _q.dispose();
    _tts.stop();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() => _loading = true);
    await _db.importFromCsvAssetIfEmpty();
    _categories = await _db.categories();
    _favIds = await _db.favoriteIds();
    await _applyFilters();
    setState(() => _loading = false);
  }

  Future<void> _applyFilters() async {
    final res = await _db.search(
      query: _q.text,
      from: _from,
      categoryFilter: _category,
      onlyFavorites: _onlyFavorites,
      limit: 250,
    );
    if (mounted) {
      setState(() => _results = res);
    }
  }

  void _swapLangs() {
    setState(() {
      final tmp = _from;
      _from = _to;
      _to = tmp;
    });
    _applyFilters();
  }

  Future<void> _speak(String text, Lang lang) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _tts.setLanguage(langCode(lang));
    await _tts.setSpeechRate(0.45);
    await _tts.setPitch(1.0);
    await _tts.speak(t);
  }

  Future<void> _toggleFavorite(Term term) async {
    final isFav = _favIds.contains(term.id);
    final next = !isFav;
    await _db.setFavorite(term.id, next);
    _favIds = await _db.favoriteIds();
    if (mounted) setState(() {});
    if (_onlyFavorites) _applyFilters();
  }

  Future<void> _openHistory() async {
    final history = await _db.getHistory();
    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) {
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Expanded(child: Text('Historial de búsquedas', style: TextStyle(fontWeight: FontWeight.w700))),
                  TextButton(
                    onPressed: () async {
                      await _db.clearHistory();
                      if (mounted) Navigator.pop(context);
                    },
                    child: const Text('Borrar'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (history.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Aún no hay historial.'),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: history.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final q = history[i];
                      return ListTile(
                        title: Text(q),
                        onTap: () {
                          Navigator.pop(context);
                          _q.text = q;
                          _q.selection = TextSelection.fromPosition(TextPosition(offset: q.length));
                        },
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openFavorites() async {
    final favs = await _db.getFavorites();
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => FavoritesScreen(favorites: favs)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diccionario Culinario'),
        actions: [
          IconButton(
            tooltip: 'Historial',
            onPressed: _openHistory,
            icon: const Icon(Icons.history),
          ),
          IconButton(
            tooltip: 'Favoritos',
            onPressed: _openFavorites,
            icon: const Icon(Icons.star),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                  child: TextField(
                    controller: _q,
                    decoration: InputDecoration(
                      labelText: 'Buscar (offline)',
                      hintText: 'Ej: merluza, hake, Kabeljau…',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _q.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () => _q.clear(),
                            ),
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (v) async {
                      await _db.addHistory(v);
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _category,
                          decoration: const InputDecoration(
                            labelText: 'Categoría',
                            border: OutlineInputBorder(),
                          ),
                          items: _categories
                              .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                              .toList(),
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() => _category = v);
                            _applyFilters();
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<Lang>(
                                value: _from,
                                decoration: const InputDecoration(
                                  labelText: 'De',
                                  border: OutlineInputBorder(),
                                ),
                                items: Lang.values
                                    .map((l) => DropdownMenuItem(value: l, child: Text(langLabel(l))))
                                    .toList(),
                                onChanged: (v) {
                                  if (v == null) return;
                                  setState(() => _from = v);
                                  _applyFilters();
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: 'Intercambiar',
                              onPressed: _swapLangs,
                              icon: const Icon(Icons.swap_horiz),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: DropdownButtonFormField<Lang>(
                                value: _to,
                                decoration: const InputDecoration(
                                  labelText: 'A',
                                  border: OutlineInputBorder(),
                                ),
                                items: Lang.values
                                    .map((l) => DropdownMenuItem(value: l, child: Text(langLabel(l))))
                                    .toList(),
                                onChanged: (v) {
                                  if (v == null) return;
                                  setState(() => _to = v);
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Solo favoritos'),
                    value: _onlyFavorites,
                    onChanged: (v) {
                      setState(() => _onlyFavorites = v);
                      _applyFilters();
                    },
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _results.isEmpty
                      ? const Center(child: Text('Sin resultados'))
                      : ListView.separated(
                          itemCount: _results.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final t = _results[i];
                            final left = t.valueFor(_from);
                            final right = t.valueFor(_to);
                            final isFav = _favIds.contains(t.id);

                            return ListTile(
                              title: Text(left.isEmpty ? '—' : left),
                              subtitle: Text('${right.isEmpty ? '—' : right}  •  ${t.category}'),
                              leading: IconButton(
                                tooltip: isFav ? 'Quitar de favoritos' : 'Añadir a favoritos',
                                icon: Icon(isFav ? Icons.star : Icons.star_border),
                                onPressed: () => _toggleFavorite(t),
                              ),
                              trailing: IconButton(
                                tooltip: 'Pronunciar (${langLabel(_to)})',
                                icon: const Icon(Icons.volume_up),
                                onPressed: () => _speak(right, _to),
                              ),
                              onTap: () async {
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => TermDetailScreen(term: t)),
                                );
                                // refrescar favoritos al volver
                                _favIds = await _db.favoriteIds();
                                if (mounted) setState(() {});
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

class TermDetailScreen extends StatefulWidget {
  final Term term;
  const TermDetailScreen({super.key, required this.term});

  @override
  State<TermDetailScreen> createState() => _TermDetailScreenState();
}

class _TermDetailScreenState extends State<TermDetailScreen> {
  final _tts = FlutterTts();

  Future<void> _speak(String text, Lang lang) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _tts.setLanguage(langCode(lang));
    await _tts.setSpeechRate(0.45);
    await _tts.speak(t);
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  Widget _row(String label, String value, Lang lang) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(value.isEmpty ? '—' : value)),
          IconButton(
            tooltip: 'Pronunciar',
            icon: const Icon(Icons.volume_up),
            onPressed: value.trim().isEmpty ? null : () => _speak(value, lang),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.term;
    return Scaffold(
      appBar: AppBar(title: Text(t.es.isEmpty ? 'Detalle' : t.es)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            Text(t.category, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            _row('Español', t.es, Lang.es),
            _row('English', t.en, Lang.en),
            _row('Deutsch', t.de, Lang.de),
            _row('Français', t.fr, Lang.fr),
            const SizedBox(height: 8),
            if (t.synonymsEs.trim().isNotEmpty)
              Text('Sinónimos: ${t.synonymsEs}', style: Theme.of(context).textTheme.bodySmall),
            if (t.notes.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Notas: ${t.notes}', style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }
}

class FavoritesScreen extends StatelessWidget {
  final List<Term> favorites;
  const FavoritesScreen({super.key, required this.favorites});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Favoritos')),
      body: favorites.isEmpty
          ? const Center(child: Text('Aún no has añadido favoritos.'))
          : ListView.separated(
              itemCount: favorites.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final t = favorites[i];
                return ListTile(
                  title: Text(t.es.isEmpty ? '—' : t.es),
                  subtitle: Text(t.category),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => TermDetailScreen(term: t)),
                  ),
                );
              },
            ),
    );
  }
}
