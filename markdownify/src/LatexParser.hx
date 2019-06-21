import hxparse.LexerTokenSource;
import hxparse.Parser;
import LatexToken;

using StringTools;

typedef Section = {
	title: String,
	label: String,
	content: String,
	sub: Array<Section>,
	parent: Null<Section>,
	index: Int,
	id: String,
	source: {
		file: String,
		lineMin: Int,
		lineMax: Int
	}
}

enum ListMode {
	Itemize;
	Enumerate(c:Int);
	Description;
}

enum LabelKind {
	Section(sec:Section);
	Item(i:Int);
	Definition;
	Paragraph(sec:Section, name:String);
}

typedef Label = {
	name: String,
	kind: LabelKind
}

typedef Definition = {
	title: String,
	label: String,
	content: String
}

class LatexParser extends Parser<LexerTokenSource<LatexToken>, LatexToken> implements hxparse.ParserBuilder {

	public var labelMap:Map<String, Label>;
	public var definitions:Array<Definition>;
	public var todos:Array<String>;

	var sections:Array<Section>;
	var lastSection:Section;
	var buffer:StringBuf;
	var codeMode:Bool;
	var exprMode:Bool;
	var tableMode:Bool;
	var hlineCount:Int;
	var tableFieldCount:Int;
	var listMode:Array<ListMode>;
	var lastLabelTarget:LabelKind;
	var input:byte.ByteData;
	var config:Config;

	public function new(input, sourceName, config:Config) {
		var lexer = new LatexLexer(input, sourceName);
		var source = new hxparse.LexerTokenSource(lexer, LatexLexer.tok);
		super(source);
		this.input = input;
		this.config = config;
		buffer = new StringBuf();
		sections = [];
		labelMap = new Map();
		definitions = [];
		listMode = new Array<ListMode>();
		codeMode = false;
		exprMode = false;
		tableMode = false;
	}

	public function parse() {
		header();
		document();
		lastSection.content = getBuffer();
		return sections;
	}

	function cleanWhitespace(s:String):String {
		s = s.trim();
		s = ~/\n\t*\n/g.replace(s, "\n\n");
		s = ~/\n\n+/g.replace(s, "\n\n");
		return s;
	}

	function getBuffer() {
		return cleanWhitespace(buffer.toString());
	}

	function header() {
		while(true) {
			switch stream {
				case [TBegin("document")]: break;
				case [TEof]: throw "Found eof before \\begin{document}";
				case _: junk();
			}
		}
	}

	function document() {
		while(true) {
			switch stream {
				case [s = text2()]: buffer.add(s);

				// skip
				case [TCommand(CTitle), s = inBraces(text)]:
				case [TCommand(CAuthor), s = inBraces(text)]:
				case [TCommand(CDate), TBrOpen, TCommand(CToday), TBrClose]:
				case [TCommand(CClearpage)]:
				case [TCommand(CTableofcontents)]:
				case [TCommand(CMaketitle)]:
				case [TCommand(CNoindent)]:
				case [TCommand(CMbox), s = inBraces(text)]:

				// format
				case [TBegin("center")]:
				case [TEnd("center")]:
				case [TBegin("tabular"), _ = popt(tableFormat)]:
					tableMode = true;
					hlineCount = 0;
					tableFieldCount = 0;
				case [TEnd("tabular")]:
					tableMode = false;

				// code
				case [TCustomCommand("lang"), s = inBraces(text), TBegin("lstlisting")]:
					codeMode = true;
					buffer.add('```${s != "none" ? s : ""}');
				case [TBegin("lstlisting")]:
					codeMode = true;
					buffer.add("```haxe"); // Assume haxe if not specified
				case [TEnd("lstlisting")]:
					codeMode = false;
					buffer.add("```");
				case [TCustomEnvironment("flowchart", s, handler)]:
					var s = handler(s);
					if (s != null) {
						buffer.add(s);
					}
				case [TCommand(CInput), s = inBraces(text)]:
					if (s.startsWith("generated")) {
						buffer.add('<!--include:${s.replace(".tex", ".md")}-->');
					} else {
						var oldStream = stream;
						var oldInput = input;
						input = byte.ByteData.ofString(sys.io.File.getContent(s));
						stream = new LexerTokenSource(new LatexLexer(input, s), LatexLexer.tok);
						document();
						stream = oldStream;
						input = oldInput;
					}
				case [TCustomCommand("haxe"), options = popt(bracketArg), s = inBraces(text)]:
					buffer.add('[code asset](${s}');
					if (options != null) {
						var config = options.split(",");
						var firstline = 0;
						var lastline = 0;
						for (cfg in config) {
							var kv = cfg.split("=");
							switch(kv[0]) {
								case "firstline": firstline = Std.parseInt(kv[1]);
								case "lastline": lastline = Std.parseInt(kv[1]);
							}
						}
						if (firstline > 0 && lastline > 0) {
							buffer.add('#L${firstline}-L${lastline}');
						}
					}
					buffer.add(')\n\n');

				// custom
				case [TCustomCommand("define"), subject = popt(bracketArg), title = inBraces(text), label = inBraces(text2), content = inBraces(text2)]:
					definitions.push({
						title: title,
						label: label,
						content: content
					});
					labelMap[label] = mkLabel(label, Definition);
					buffer.add('> ##### Define: $title\n');
					buffer.add('>\n');
					content = content.replace("\r", "").split("\n").join("\n> ");
					buffer.add('> $content');
					buffer.add("\n");
				case [TCustomCommand("trivia"), title = popt(bracketArg), s = inBraces(text), s2 = inBraces(text2)]:
					buffer.add('> ##### Trivia: $s\n');
					buffer.add('>\n');
					s2 = s2.replace("\r", "").split("\n").join("\n> ");
					buffer.add('> $s2');
				case [TCustomCommand("since"), s = inBraces(text)]: buffer.add('##### since Haxe $s\n\n');
				// section
				case [TCommand(CPart), s = inBraces(text)]:
					// TODO: handle this
				case [TCommand(CChapter), s = inBraces(text)]:
					sections.push(mkSection(s, null, sections.length + 1));
				case [TCommand(CSection), _ = popt(star), s = inBraces(text)]:
					//buffer.add('### $s');
					var sec = sections[sections.length - 1];
					sec.sub.push(mkSection(s, sec, sec.sub.length + 1));
				case [TCommand(CSubsection), s = inBraces(text)]:
					//buffer.add('#### $s');
					var sec = sections[sections.length - 1].sub;
					var sec = sec[sec.length - 1];
					sec.sub.push(mkSection(s, sec, sec.sub.length + 1));
				case [TCommand(CParagraph), s = inBraces(text)]:
					lastLabelTarget = Paragraph(lastSection, s);
					buffer.add('##### $s');
				// misc
				case [TCommand(CTextless)]:
					buffer.add("&lt;"); // escaped so MD doesn't parse it as HTML
				case [TCommand(CTextgreater)]:
					buffer.add("&gt;");
				case [TCommand(CTextbar)]:
					buffer.add("&#x7C;"); // escaped so it doesn't interfere with tables

				case [TEnd("document")]: break;
				case [TEof]: break;
			}
		}
	}

	function text() {
		var s = _text();
		if (s == null) noMatch();
		var s2 = popt(text);
		return if (s2 == null) s else s + s2;
	}

	function _text() {
		return switch stream {
			case [TText(s)]: s;
			case [TTab]:
				codeMode ? "\t" : "";
			case [TDollarLiteral]: "$";
			case [TDollar]: codeMode ? "$" : "";
			case [TTilde]: codeMode ? "~" : "&nbsp;";
			case [TAmp]:
				if (tableMode && !exprMode) {
					if (hlineCount == 1) tableFieldCount++;
					"|";
				} else {
					"&";
				}
			case [TCommand(CTextasciitilde)]: "~";
			case [TCommand(CTextbackslash)]: "\\";
			case [TCommand(CSlash)]: "/";
			case [TCommand(CEmph), s = inBraces(text)]: '**$s**';
			case [TCommand(CTextsuperscript), s = inBraces(text)]:'<sup>$s</sup>';
			case [TBrOpen && codeMode]: "{";
			case [TBrClose && codeMode]: "}";
			case [TBkOpen && (codeMode || exprMode)]: "[";
			case [TBkClose && (codeMode || exprMode)]: "]";
			case [TCommand(CLeft)]: "";
			case [TCommand(CRight)]: "";
			case [TCustomCommand("target"), s = inBraces(text)]: s;
			case [TCustomCommand("expr" | "ic")]:
				exprMode = true;
				var s = switch stream {
					case [TBrOpen, s = text(), TBrClose]:
						if (tableMode || s.indexOf("|") != -1) {
							s = s.htmlEscape().replace("|", "&#124;").replace("_", "&#95;");
							'<code>$s</code>';
						} else {
							'`$s`';
						}
					case _: unexpected();
				}
				exprMode = false;
				s;
			case [TCommand(CTexttt), s = inBraces(text)]: '`$s`';
			case [TCustomCommand("type"), s = inBraces(text)]: '`$s`';
			case [s = ref()]: s;
			case [TCustomCommand("href"), s1 = inBraces(text), s2 = inBraces(text)]: '[$s2]($s1)';
			case [TCommand(CUrl), s = inBraces(text)]: '<$s>';
			case [TCommand(CLabel), s = inBraces(text)]:
				var name = switch(lastLabelTarget) {
					case Section(sec):
						lastSection.label = s;
						sec.title;
					case Item(i):
						"" + i;
					case Paragraph(_, name):
						name;
					case Definition:
						throw false;
				}
				labelMap[s] = mkLabel(name, lastLabelTarget);
				"";
			case [TCommand(CHline)]:
				if (tableMode) {
					hlineCount++;
					if (hlineCount == 2) {
						[for (i in 0...tableFieldCount + 1) "---"].join(" | ") + "\n";
					} else {
						"";
					}
				} else {
					"---\n";
				}
			case [TNewline]: tableMode || listMode.length > 0 ? "" : "\n";
			case [TDoubleBackslash]: "\n";
			case [TCommand(CTextasciicircum)]: "^";
			case [s = inBraces(text)]: s;
		}
	}

	function text2() {
		var s = _text2();
		if (s == null) noMatch();
		var s2 = popt(text2);
		return if (s2 == null) s else s + s2;
	}

	function _text2() {
		return switch stream {
			// list
			case [TBegin("itemize")]:
				listMode.push(Itemize);
				"\n";
			case [TBegin("description")]:
				listMode.push(Description);
				"\n";
			case [TBegin("enumerate")]:
				listMode.push(Enumerate(1));
				lastLabelTarget = Item(1);
				"\n";
			case [TCommand(CItem), subject = popt(bracketArg), s = text()]:
				var bullet = switch(listMode[listMode.length - 1]) {
					case Enumerate(c):
						listMode[listMode.length - 1] = Enumerate(c + 1);
						lastLabelTarget = Item(c + 1);
						'$c.';
					case (Description | Itemize) if (subject != null):
						'* $subject';
					case Description | Itemize:
						'*';
				}
				var indent = "".lpad("    ", (listMode.length - 1) * 2);
				'$indent$bullet$s\n';
			case [TEnd("itemize")]:
				listMode.pop();
				"";
			case [TEnd("description")]:
				listMode.pop();
				"";
			case [TEnd("enumerate")]:
				listMode.pop();
				"";
			// TODO
			case [TCommand(CFootnote), s = inBraces(text)]: "";
			case [t = _text()]:
				t;
		}
	}

	function ref() {
		return switch stream {
			case [TCommand(CRef), TBrOpen, s = text(), TBrClose]: '~~~$s~~~';
			case [TCustomCommand("Fullref"), TBrOpen, s = text(), TBrClose]: '~~~$s~~~';
			case [TCustomCommand("tref"), TBrOpen, s1 = text(), TBrClose, TBrOpen, s2 = text(), TBrClose]: '[$s1](~~$s2~~)';
		}
	}

	function tableFormat() {
		return switch stream {
			case [TBrOpen, s = text(), TBrClose]: s;
			case _: null;
		}
	}

	function bracketArg() {
		return switch stream {
			case [TBkOpen, s = text(), TBkClose]: s;
		}
	}

	function emptyBraces(){
		return switch stream {
			case [TBrOpen, TBrClose]: "";
		}
	}

	function inBraces(f:Void->String) {
		return switch stream {
			case [TBrOpen]:
				switch stream {
					case [r = f(), TBrClose]: r;
					case [TBrClose]: "";
				}
		}
	}

	function star() {
		return switch stream {
			case [TText("*")]:
				true;
		}
	}

	function popt<T>(f:Void->T):Null<T> {
		return switch stream {
			case [v = f()]: v;
			case _: null;
		}
	}

	function mkSection(title:String, parent:Section, index:Int) {
		if (lastSection != null) {
			lastSection.content = getBuffer();
			buffer = new StringBuf();
		}
		var id = (parent != null ? parent.id + "." : "") + index;
		lastSection = {
			title: title,
			label: null,
			content: "",
			sub: [],
			parent: parent,
			index: index,
			id: id,
			source: null
		};
		lastLabelTarget = Section(lastSection);
		return lastSection;
	}

	function mkLabel(name:String, kind:LabelKind) {
		return {
			name: name,
			kind: kind
		}
	}
}