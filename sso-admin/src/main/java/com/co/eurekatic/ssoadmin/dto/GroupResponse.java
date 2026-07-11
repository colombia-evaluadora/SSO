package com.co.eurekatic.ssoadmin.dto;

import com.co.eurekatic.common.entity.Group;

import java.util.List;

/**
 * Response shape for {@code GET /group}. {@code memberCount} is
 * the number of users in the group, exposed so the UI can show
 * "Group X (12 members)" without an extra round-trip.
 */
public record GroupResponse(
        Long id,
        String name,
        String description,
        int memberCount
) {
    public static GroupResponse fromEntity(Group g) {
        return new GroupResponse(
                g.getId(),
                g.getName(),
                g.getDescription(),
                g.getUsers() == null ? 0 : g.getUsers().size());
    }

    public static List<GroupResponse> fromEntities(List<Group> groups) {
        return groups.stream().map(GroupResponse::fromEntity).toList();
    }
}
