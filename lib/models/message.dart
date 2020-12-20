import 'package:enough_mail/enough_mail.dart';
import 'package:enough_mail_app/util/html_util.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart' as urlLauncher;

import 'message_source.dart';

class Message extends ChangeNotifier {
  static const String keywordFlagUnsubscribed = r'$Unsubscribed';

  MimeMessage mimeMessage;
  final MailClient mailClient;
  int sourceIndex;
  final MessageSource source;

  Message(this.mimeMessage, this.mailClient, this.source, this.sourceIndex);

  bool get hasNext => (next != null);
  Message get next => source.next(this);
  bool get hasPrevious => (sourceIndex > 0);
  Message get previous => source.previous(this);

  bool get isSeen => mimeMessage.isSeen;
  set isSeen(bool value) {
    mimeMessage.isSeen = value;
    notifyListeners();
  }

  bool get isFlagged => mimeMessage.isFlagged;
  set isFlagged(bool value) {
    mimeMessage.isFlagged = value;
    notifyListeners();
  }

  bool get isAnswered => mimeMessage.isAnswered;
  set isAnswered(bool value) {
    mimeMessage.isAnswered = value;
    notifyListeners();
  }

  bool get isForwarded => mimeMessage.isForwarded;
  set isForwarded(bool value) {
    mimeMessage.isForwarded = value;
    notifyListeners();
  }

  bool get isDeleted => mimeMessage.isDeleted;
  set isDeleted(bool value) {
    mimeMessage.isDeleted = value;
    notifyListeners();
  }

  bool get isMdnSent => mimeMessage.isMdnSent;
  set isMdnSent(bool value) {
    mimeMessage.isMdnSent = value;
    notifyListeners();
  }

  bool get isNewsLetter => mimeMessage.isNewsletter;

  bool get isNewsLetterSubscribable => mimeMessage.isNewsLetterSubscribable;

  bool get isNewsletterUnsubscribed =>
      mimeMessage.hasFlag(keywordFlagUnsubscribed);
  set isNewsletterUnsubscribed(bool value) {
    mimeMessage.setFlag(keywordFlagUnsubscribed, value);
    notifyListeners();
  }

  void updateFlags(List<String> flags) {
    mimeMessage.flags = flags;
    notifyListeners();
  }

  void updateMime(MimeMessage mime) {
    this.mimeMessage = mime;
    notifyListeners();
  }

  String decodeAndStripHtml() {
    var html = mimeMessage.decodeTextHtmlPart();
    return HtmlUtil.stripConditionals(html);
  }
}

extension NewsLetter on MimeMessage {
  bool get isEmpty => (bodyRaw == null && envelope == null && body == null);

  /// Checks if this is a newsletter with a `list-unsubscribe` header.
  bool get isNewsletter => hasHeader('list-unsubscribe');

  /// Checks if this is a newsletter with a `list-subscribe` header.
  bool get isNewsLetterSubscribable => hasHeader('list-subscribe');

  /// Retrieves the List-Unsubscribe URIs, if present
  List<Uri> decodeListUnsubscribeUris() {
    return _decodeUris('list-unsubscribe');
  }

  List<Uri> decodeListSubscribeUris() {
    return _decodeUris('list-subscribe');
  }

  String decodeListName() {
    final listPost = decodeHeaderValue('list-post');
    if (listPost != null) {
      // tyically only mailing lists that allow posting have a human understandable List-ID header:
      final id = decodeHeaderValue('list-id');
      if (id != null && id.isNotEmpty) {
        return id;
      }
      final startIndex = listPost.indexOf('<mailto:');
      if (startIndex != null) {
        final endIndex = listPost.indexOf('>', startIndex + '<mailto:'.length);
        if (endIndex != -1) {
          return listPost.substring(startIndex + '<mailto:'.length, endIndex);
        }
      }
    }
    final sender = decodeSender();
    if (sender?.isNotEmpty ?? false) {
      return sender.first.toString();
    }
    return null;
  }

  List<Uri> _decodeUris(final String name) {
    final value = getHeaderValue(name);
    if (value == null) {
      return null;
    }
    //TODO allow comments in / before URIs, e.g. "(send a mail to unsubscribe) <mailto:unsubscribe@list.org>"
    final uris = <Uri>[];
    final parts = value.split('>');
    for (var part in parts) {
      part = part.trimLeft();
      if (part.startsWith(',')) {
        part = part.substring(1).trimLeft();
      }
      if (part.startsWith('<')) {
        part = part.substring(1);
      }
      if (part.isNotEmpty) {
        final uri = Uri.tryParse(part);
        if (uri == null) {
          print('Invalid $name $value: unable to pars URI $part');
        } else {
          uris.add(uri);
        }
      }
    }
    return uris;
  }

  bool hasListUnsubscribePostHeader() {
    return hasHeader('list-unsubscribe-post');
  }

  Future<bool> unsubscribe(MailClient client) async {
    final uris = decodeListUnsubscribeUris();
    if (uris == null) {
      return false;
    }
    final httpUri = uris.firstWhere(
        (uri) => uri.scheme.toLowerCase() == 'https',
        orElse: () => uris.firstWhere(
            (uri) => uri.scheme.toLowerCase() == 'http',
            orElse: () => null));
    // unsubscribe via one click POST request: https://tools.ietf.org/html/rfc8058
    if (hasListUnsubscribePostHeader() && httpUri != null) {
      var response = await unsubscribeWithOneClick(httpUri);
      if (response?.statusCode == 200) {
        return true;
      }
    }
    // unsubscribe via generated mail:
    final mailtoUri = uris.firstWhere(
        (uri) => uri.scheme.toLowerCase() == 'mailto',
        orElse: () => null);
    if (mailtoUri != null) {
      var sendResponse = await sendMailto(mailtoUri, client, 'unsubscribe');
      if (sendResponse.isOkStatus) {
        return true;
      }
    }
    // manually open unsubscribe web page:
    if (httpUri != null) {
      return urlLauncher.launch(httpUri.toString());
    }
    return false;
  }

  Future<bool> subscribe(MailClient client) async {
    final uris = decodeListSubscribeUris();
    if (uris == null) {
      return false;
    }
    // subscribe via generated mail:
    final mailtoUri = uris.firstWhere(
        (uri) => uri.scheme.toLowerCase() == 'mailto',
        orElse: () => null);
    if (mailtoUri != null) {
      var sendResponse = await sendMailto(mailtoUri, client, 'subscribe');
      if (sendResponse.isOkStatus) {
        return true;
      }
    }
    // manually open subscribe web page:
    final httpUri = uris.firstWhere(
        (uri) => uri.scheme.toLowerCase() == 'https',
        orElse: () => uris.firstWhere(
            (uri) => uri.scheme.toLowerCase() == 'http',
            orElse: () => null));
    if (httpUri != null) {
      return urlLauncher.launch(httpUri.toString());
    }
    return false;
  }

  Future<http.StreamedResponse> unsubscribeWithOneClick(Uri uri) {
    var request = http.MultipartRequest('POST', uri)
      ..fields['List-Unsubscribe'] = 'One-Click';
    return request.send();
  }

  Future<MailResponse> sendMailto(
      Uri mailtoUri, MailClient client, String defaultSubject) {
    final account = client.account;
    var me = findRecipient(account.fromAddress,
        aliases: account.aliases,
        allowPlusAliases: account.supportsPlusAliases);
    me ??= account.fromAddress;
    final builder = MessageBuilder.prepareMailtoBasedMessage(mailtoUri, me);
    if (builder.subject == null) {
      builder.subject = defaultSubject;
    }
    if (builder.text == null) {
      builder.text = defaultSubject;
    }
    final message = builder.buildMimeMessage();
    return client.sendMessage(message);
  }
}