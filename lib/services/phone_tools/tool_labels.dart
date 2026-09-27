/// 工具的显示名。
///
/// 折叠行上原来直接印 `write_diary_entry`、`get_book_highlights` 这种标识符——
/// 那是给写代码的人看的，带下划线，一眼就是代码，出现在聊天里像漏了什么不该
/// 看的东西。
///
/// 但也没换成中文。这一行是过程信息，本来就该往后退，而方块字的笔画密度比
/// 拉丁字母高，同样字号下视觉重量大得多，「写日记」三个字比 `Write diary`
/// 更容易被读进去——可你并不需要每次都读它，余光扫过知道做了点什么就够了。
/// 英文还有个附带好处：整屏中文里冒出一行英文，大脑会自动把它归到「系统信息」
/// 那一类，和正文分开。
///
/// 所以是「英文，但不是标识符」。只换折叠行，展开后仍显示原始名——排查时要靠
/// 它对上是哪个工具（web_search 发空 query 那次就是这么看出来的）。
const _labels = <String, String>{
  'take_photo': 'Take photo',
  'pick_image': 'Pick image',
  'pick_file': 'Pick file',
  'read_file': 'Read file',
  'write_file': 'Write file',
  'list_files': 'List files',
  'read_clipboard': 'Read clipboard',
  'get_location': 'Location',
  'get_sensors': 'Sensors',
  'web_search': 'Web search',
  'search_news': 'News search',
  'get_weather': 'Weather',
  'write_diary_entry': 'Write diary',
  'recall_records': 'Recall records',
  'save_to_corner': 'Save to corner',
  'memory': 'Memory',
  'follow_up_later': 'Note to self',
  // 「一起听歌」。放/停/切歌都归这一行。不叫 'Now playing' 是因为它不止是读的
  // ——暂停也是它，写「正在播放」会把一次打断说成一次查看。
  'music': 'Music',
  'glance_screen': 'Glance at screen',
  'add_small_thing': 'Small thing',
  'set_alarm': 'Set alarm',
  'set_timer': 'Set timer',
  'add_calendar_event': 'Add to calendar',
  'list_calendar_events': 'Read calendar',
  'list_highlighted_books': 'Highlighted books',
  'get_book_highlights': 'Book highlights',
};

/// 认识的就翻译，不认识的原样返回。
///
/// 外部 MCP 服务器接进来的工具不在这张表里，那时候显示原始名反而是对的——
/// 编一个名字会让人以为是内置能力。
String toolDisplayName(String name) => _labels[name] ?? name;
