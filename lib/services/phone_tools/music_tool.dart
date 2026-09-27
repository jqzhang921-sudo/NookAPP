import '../../models/mcp_tool.dart';
import '../music_service.dart';

/// 「一起听歌」：知道 TA 在听什么，也能替 TA 动播放器。
///
/// ## 这个工具最要紧的一条不是「能做什么」，是「什么时候不许动」
///
/// 播放控制是所有手机工具里**唯一一个会打断用户当下正在做的事**的。查天气查错
/// 了只是白查一次；把人家正在听的歌切掉，是实打实地从 TA 耳朵里抢走东西。
///
/// 所以描述里那句「只有 TA 明确说了才能切」写得比功能说明还长。这不是过度
/// 谨慎——模型看到 `next` 这个动作就在手边，配上它「想帮忙」的倾向，很容易
/// 自己判断「这首不太合适，帮她换一首」。那条路走到头就是用户关掉这个功能。
///
/// 读的部分（`now_playing`）反过来，随便查，它不改任何东西。
class MusicTool {
  /// 播放器包名 → 给人看的名字。
  ///
  /// 只列实测见过的几个。认不出来就原样报包名——**不要**猜成「某个音乐 App」，
  /// 模型会拿那个去跟用户说，说错了还不如说不知道。
  static const _apps = {
    'com.netease.cloudmusic': '网易云音乐',
    'com.tencent.qqmusic': 'QQ音乐',
    'app.podcast.cosmos': '小宇宙',
    'com.ximalaya.ting.android': '喜马拉雅',
    'tv.danmaku.bili': '哔哩哔哩',
  };

  static McpTool get definition => McpTool(
    name: 'music',
    description:
        'TA 在听什么，以及替 TA 动播放器。\n\n'
        'action 六选一：\n'
        '· now_playing —— 现在在放哪首歌：歌名、歌手、专辑、在放还是暂停、'
        '放到哪儿了、总共多长。**不动任何东西，随便查。**\n'
        '· play / pause —— 开始放 / 暂停。\n'
        '· play_pause —— 按一下那个键：在放就暂停，暂停就开始放。'
        '用户说「停一下」但你拿不准现在是在放还是暂停，用这个。\n'
        '· next / previous —— 下一首 / 上一首。\n'
        '· seek —— 跳到某个位置，要给 position_ms（毫秒，从歌头算）。\n\n'
        '⚠️ 用控制之前先想清楚：**TA 正在听，切歌和暂停是打断，不是帮忙。**\n'
        '只有 TA 明说了「换一首」「下一首」「别放了」这类话，才能调 '
        'next / previous / pause。**不要**觉得「这首歌好像不合现在的气氛」'
        '就自己切掉——那是 TA 选的歌，TA 想听。\n'
        '「听听这个」这种推荐式的请求**不是**切歌指令，先把话说出来，'
        'TA 自己要听会跟你要。\n\n'
        '不知道在放什么就先 now_playing。但**别每轮都查**——TA 没提音乐的'
        '时候，你不需要知道。\n\n'
        '控制可能失败：没在放歌、或者那个 App 不给第三方控制。失败时返回的是'
        '一句中文说明，照它说给用户听，别自己编原因。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': [
            'now_playing',
            'play',
            'pause',
            'play_pause',
            'next',
            'previous',
            'seek',
          ],
          'description': '要做哪件事。',
        },
        'position_ms': {
          'type': 'integer',
          'description':
              'seek 要：跳到第几毫秒，从歌头算。'
              '「跳到一分钟」= 60000，「从头放」= 0。',
        },
      },
      'required': ['action'],
    },
    category: '手机工具',
  );

  static Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    final action = '${args['action'] ?? ''}'.trim().toLowerCase();

    // 除了 now_playing，其余全要先看一眼在不在放——不然「暂停」成功了、
    // 用户却什么都没听到，两边都不知道为什么。
    if (action == 'now_playing') return nowPlaying();

    const controls = {
      'play': 'play',
      'pause': 'pause',
      'play_pause': 'play_pause',
      'next': 'next',
      'previous': 'previous',
    };

    if (action == 'seek') {
      final ms = (args['position_ms'] as num?)?.toInt();
      if (ms == null) {
        return {
          'success': false,
          'error': 'seek 要带 position_ms（毫秒）。「跳到 1 分钟」就是 60000。',
        };
      }
      return _control('seek', position: Duration(milliseconds: ms));
    }

    final cmd = controls[action];
    if (cmd == null) {
      return {
        'success': false,
        'error':
            'action 要是 now_playing / play / pause / play_pause / next / '
            "previous / seek 之一，收到的是「${args['action']}」。",
      };
    }
    return _control(cmd);
  }

  // ---------------- 读 ----------------

  /// 现在在放什么。
  ///
  /// 「没在放歌」**不是错误**——问题被如实回答了。所以走 `success: true` 配
  /// `playing: false`，而不是失败。混在一起的话，模型会以为工具坏了、去重试，
  /// 或者在「它答不上来」和「现在没歌」之间编一个出来。
  static Future<Map<String, dynamic>> nowPlaying() async {
    final svc = MusicService.instance;
    // 重新问一次权限 + 拉一份当前状态。可以重复调（见 MusicService.start）。
    // 不这么做的话，用户刚在别的 App 里切了歌，这里读到的还是上一次的。
    await svc.start();

    if (!svc.granted) {
      return {
        'success': false,
        'error':
            '没有「通知使用权」，读不到任何播放器。'
            '去「栖息 → 一起听」那一页有开启按钮，需要用户自己点一下。',
      };
    }

    final now = svc.now;
    if (now == null) {
      return {
        'success': true,
        'playing': false,
        'message': '现在没读到在放的歌。TA 可能没在听。',
      };
    }

    final t = now.track;
    final total = t.duration;
    final pos = now.livePosition;

    return {
      'success': true,
      'playing': now.state.isPlaying,
      'title': t.title,
      'artist': t.artist,
      'album': t.album,
      'state': now.state.label,
      'position_ms': pos.inMilliseconds,
      'duration_ms': total?.inMilliseconds,
      'from': _apps[t.package] ?? t.package,
      // stale = 原生那边元数据被清空了，这条是拿上一首顶上的。必须说出来，
      // 不然模型会拿「上次在听」当「现在在放」讲给用户。
      if (t.stale)
        'note': '这条是从上一次读到的缓存来的——播放器现在没报元数据。'
            '别当成「正在放」。',
    };
  }

  // ---------------- 写 ----------------

  static Future<Map<String, dynamic>> _control(
    String action, {
    Duration? position,
  }) async {
    final svc = MusicService.instance;
    if (!svc.granted) {
      return {
        'success': false,
        'error': '没有「通知使用权」，控制不了播放器。得用户自己去开启。',
      };
    }

    final err = await svc.control(action, position: position);
    if (err != null) return {'success': false, 'error': err};

    return {
      'success': true,
      'message': switch (action) {
        'play' => '开始放了。',
        'pause' => '暂停了。',
        // 这里读的是**乐观更新之后**的状态（见 MusicService.control），不是
        // 播放器回的话——它可能压根不回。写「现在…」而不是「已暂停」，
        // 就是为了不把话说死。
        'play_pause' => '按了一下播放键，现在${svc.now?.state.label ?? "变了"}。',
        'next' => '切到下一首了。歌名要过一会儿才报上来，别急着说下一首是什么。',
        'previous' => '退回上一首了。',
        'seek' => '跳过去了。',
        _ => '发出去了。',
      },
    };
  }
}
