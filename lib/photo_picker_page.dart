import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

class PhotoPickerPage extends StatefulWidget {
  const PhotoPickerPage({super.key, required this.initialSelectedIds});

  final List<String> initialSelectedIds;

  @override
  State<PhotoPickerPage> createState() => _PhotoPickerPageState();
}

class _PhotoPickerPageState extends State<PhotoPickerPage> {
  static const int _pageSize = 120;

  final List<AssetEntity> _assets = [];
  final List<AssetPathEntity> _albums = [];
  final ValueNotifier<Set<String>> _selectedIds = ValueNotifier(<String>{});
  final ScrollController _scrollController = ScrollController();
  final Map<String, Future<Uint8List?>> _thumbnailFutures = {};

  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  String? _error;
  PermissionState? _permissionState;
  AssetPathEntity? _selectedAlbum;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _selectedIds.value = {...widget.initialSelectedIds};
    _scrollController.addListener(_handleScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _loadAssets();
      }
    });
  }

  @override
  void dispose() {
    _selectedIds.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadAssets({bool resetAlbum = true}) async {
    try {
      setState(() {
        _isLoading = true;
        _error = null;
      });

      final permission = await PhotoManager.requestPermissionExtend(
        requestOption: const PermissionRequestOption(
          androidPermission: AndroidPermission(
            type: RequestType.image,
            mediaLocation: false,
          ),
        ),
      );
      if (!mounted) return;

      _permissionState = permission;
      if (!permission.hasAccess) {
        setState(() {
          _isLoading = false;
          _error = _permissionMessage(permission);
        });
        return;
      }

      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        onlyAll: false,
        filterOption: FilterOptionGroup(
          imageOption: const FilterOption(
            sizeConstraint: SizeConstraint(ignoreSize: true),
          ),
        ),
      );

      if (!mounted) return;
      if (albums.isEmpty) {
        setState(() {
          _albums.clear();
          _assets.clear();
          _selectedAlbum = null;
          _isLoading = false;
          _error = '표시할 사진이 없습니다.';
        });
        return;
      }

      final previousAlbum = _selectedAlbum;
      final nextAlbum = !resetAlbum && previousAlbum != null
          ? albums.cast<AssetPathEntity?>().firstWhere(
              (album) => album?.id == previousAlbum.id,
              orElse: () => albums.first,
            )
          : albums.first;

      setState(() {
        _albums
          ..clear()
          ..addAll(albums);
        _selectedAlbum = nextAlbum;
      });

      await _loadAlbumAssets(reset: true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isLoadingMore = false;
        _error = '앨범을 불러오지 못했습니다.';
      });
    }
  }

  Future<void> _loadAlbumAssets({required bool reset}) async {
    try {
      final album = _selectedAlbum;
      if (album == null) {
        setState(() {
          _isLoading = false;
          _isLoadingMore = false;
          _error = '앨범을 불러오지 못했습니다.';
        });
        return;
      }

      if (reset) {
        _currentPage = 0;
        _hasMore = true;
        _thumbnailFutures.clear();
        setState(() {
          _assets.clear();
        });
      } else {
        if (_isLoadingMore || !_hasMore) return;
        setState(() {
          _isLoadingMore = true;
        });
      }

      final page = _currentPage;
      final assets = await album.getAssetListPaged(page: page, size: _pageSize);
      if (!mounted) return;

      for (final asset in assets) {
        _thumbnailFutures.putIfAbsent(
          asset.id,
          () => asset.thumbnailDataWithSize(const ThumbnailSize(400, 400)),
        );
      }

      setState(() {
        if (reset) {
          _assets
            ..clear()
            ..addAll(assets);
          _isLoading = false;
        } else {
          _assets.addAll(assets);
          _isLoadingMore = false;
        }
        _error = _assets.isEmpty ? '표시할 사진이 없습니다.' : null;
        _hasMore = assets.length == _pageSize;
        if (assets.isNotEmpty) {
          _currentPage += 1;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isLoadingMore = false;
        _error = '앨범을 불러오지 못했습니다.';
      });
    }
  }

  void _handleScroll() {
    if (!_scrollController.hasClients ||
        _isLoading ||
        _isLoadingMore ||
        !_hasMore) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 800) {
      _loadAlbumAssets(reset: false);
    }
  }

  String _permissionMessage(PermissionState permission) {
    switch (permission) {
      case PermissionState.denied:
        return '사진 권한이 거부되었습니다. 설정에서 허용해 주세요.';
      case PermissionState.restricted:
        return '사진 접근이 제한되어 있습니다. 설정에서 확인해 주세요.';
      case PermissionState.limited:
        return '선택된 사진만 접근 가능합니다. 접근 범위를 조정할 수 있습니다.';
      case PermissionState.notDetermined:
        return '사진을 첨부하려면 사진 권한이 필요합니다.';
      case PermissionState.authorized:
        return '사진을 첨부하려면 사진 권한이 필요합니다.';
    }
  }

  Future<void> _openPermissionSettings() async {
    await PhotoManager.openSetting();
  }

  Future<void> _manageLimitedAccess() async {
    await PhotoManager.presentLimited();
    await _loadAssets(resetAlbum: false);
  }

  void _toggleAsset(AssetEntity asset) {
    final next = {..._selectedIds.value};
    if (next.contains(asset.id)) {
      next.remove(asset.id);
    } else {
      next.add(asset.id);
    }
    _selectedIds.value = next;
  }

  Future<void> _changeAlbum(AssetPathEntity? album) async {
    if (album == null || album.id == _selectedAlbum?.id) return;
    setState(() {
      _selectedAlbum = album;
      _isLoading = true;
      _error = null;
    });
    await _loadAlbumAssets(reset: true);
  }

  Future<void> _completeSelection() async {
    final selectedIds = _selectedIds.value;
    final selectedAssets = _assets.where((asset) => selectedIds.contains(asset.id)).toList();
    Navigator.of(context).pop(selectedAssets);
  }

  @override
  Widget build(BuildContext context) {
    final bottomSafeArea = MediaQuery.of(context).viewPadding.bottom;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('사진 선택'),
        actions: [
          if (_permissionState == PermissionState.limited)
            IconButton(
              onPressed: _manageLimitedAccess,
              icon: const Icon(Icons.tune_outlined),
              tooltip: '선택 가능한 사진 관리',
            ),
          ValueListenableBuilder<Set<String>>(
            valueListenable: _selectedIds,
            builder: (context, selectedIds, child) {
              return TextButton(
                onPressed: _completeSelection,
                child: Text(
                  '완료 (${selectedIds.length})',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: _buildBody(bottomSafeArea),
    );
  }

  Widget _buildBody(double bottomSafeArea) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 16),
              if (_permissionState == PermissionState.denied ||
                  _permissionState == PermissionState.restricted)
                FilledButton(
                  onPressed: _openPermissionSettings,
                  child: const Text('설정 열기'),
                ),
              if (_permissionState == PermissionState.limited) ...[
                FilledButton(
                  onPressed: _manageLimitedAccess,
                  child: Text(Platform.isIOS ? '선택한 사진 관리' : '접근 범위 확인'),
                ),
                const SizedBox(height: 12),
              ],
              FilledButton(onPressed: _loadAssets, child: const Text('다시 시도')),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          color: Colors.black,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _permissionState == PermissionState.limited
                    ? '선택된 사진만 접근 중입니다. 필요한 경우 범위를 조정해 주세요.'
                    : '여러 장을 선택해 증거로 첨부할 수 있습니다.',
                style: const TextStyle(color: Colors.white70, height: 1.4),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF161B22),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<AssetPathEntity>(
                    value: _selectedAlbum,
                    isExpanded: true,
                    dropdownColor: const Color(0xFF161B22),
                    iconEnabledColor: Colors.white70,
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                    items: _albums
                        .map(
                          (album) => DropdownMenuItem<AssetPathEntity>(
                            value: album,
                            child: Text(
                              album.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: _changeAlbum,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              GridView.builder(
                controller: _scrollController,
                padding: EdgeInsets.fromLTRB(4, 4, 4, bottomSafeArea + 12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 4,
                  mainAxisSpacing: 4,
                ),
                itemCount: _assets.length,
                itemBuilder: (context, index) {
                  final asset = _assets[index];
                  final thumbnailFuture = _thumbnailFutures.putIfAbsent(
                    asset.id,
                    () => asset.thumbnailDataWithSize(const ThumbnailSize(400, 400)),
                  );
                  return _AssetTile(
                    key: ValueKey(asset.id),
                    asset: asset,
                    thumbnailFuture: thumbnailFuture,
                    selectedIds: _selectedIds,
                    onTap: () => _toggleAsset(asset),
                  );
                },
              ),
              if (_isLoadingMore)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: bottomSafeArea + 12,
                  child: const Center(child: CircularProgressIndicator()),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AssetTile extends StatelessWidget {
  const _AssetTile({
    super.key,
    required this.asset,
    required this.thumbnailFuture,
    required this.selectedIds,
    required this.onTap,
  });

  final AssetEntity asset;
  final Future<Uint8List?> thumbnailFuture;
  final ValueNotifier<Set<String>> selectedIds;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _AssetThumb(thumbnailFuture: thumbnailFuture),
          ValueListenableBuilder<Set<String>>(
            valueListenable: selectedIds,
            builder: (context, currentSelectedIds, child) {
              final selected = currentSelectedIds.contains(asset.id);
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (selected)
                    Container(color: Colors.green.withValues(alpha: 0.28)),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: selected ? const Color(0xFF22C55E) : Colors.black54,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                      child: Icon(
                        selected ? Icons.check : Icons.add,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AssetThumb extends StatelessWidget {
  const _AssetThumb({required this.thumbnailFuture});

  final Future<Uint8List?> thumbnailFuture;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: thumbnailFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Container(color: const Color(0xFF1F2937));
        }
        final data = snapshot.data;
        if (data == null) {
          return Container(
            color: const Color(0xFF1F2937),
            child: const Icon(
              Icons.image_not_supported_outlined,
              color: Colors.white54,
            ),
          );
        }
        return Image.memory(data, fit: BoxFit.cover, gaplessPlayback: true);
      },
    );
  }
}
